############################################
# HelloID-Conn-Prov-Target-ServiceNow-Update
#
# Version: 1.0.1
############################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$m = $manager | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Correlation values
$managerCorrelationProperty = "email" # Has to match the name of the unique identifier
$managerCorrelationValue = $m.Accounts.MicrosoftActiveDirectory.userPrincipalName # Has to match the value of the unique identifier

# Account mapping
$account = [PSCustomObject]@{
    user_name       = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    employee_number = $p.ExternalId
    email           = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    first_name      = $p.Name.Nickname
    last_name       = $p.Accounts.MicrosoftActiveDirectory.sn
    gender          = switch ($p.Details.Gender) {
        'F' { 'Female' }
        'M' { 'Male' }
        'X' { 'Undefined' }
    }
    home_phone      = $p.contact.Personal.phone.Fixed
    street          = $p.contact.Personal.Address.Street
    zip_code        = $p.contact.Personal.Address.PostalCode
    city            = $p.contact.Personal.Address.Locality
    country         = $p.contact.Personal.Address.Country
    phone           = $p.Contact.Business.Phone.Fixed
    mobile_phone    = $p.Contact.Business.Phone.Mobile
    department      = $p.PrimaryContract.Department.DisplayName
    manager         = "" # manager is determined automatically later in script
    title           = $p.PrimaryContract.Title.Name
    location        = $p.PrimaryContract.Department.DisplayName
}

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Resolve-ServiceNowError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }

        try {
            if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
                $rawErrorMessage = ($ErrorObject.ErrorDetails.Message | ConvertFrom-Json)
                $httpErrorObj.ErrorDetails = "Error: $($rawErrorMessage.error.message), details: $($rawErrorMessage.error.detail), status: $($rawErrorMessage.status)"
                $httpErrorObj.FriendlyMessage = $rawErrorMessage.error.message
            }
            elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if ($null -ne $streamReaderResponse) {
                    $rawErrorMessage = ($streamReaderResponse | ConvertFrom-Json)
                    $httpErrorObj.ErrorDetails = "Error: $($rawErrorMessage.error.message), details: $($rawErrorMessage.error.detail), status: $($rawErrorMessage.status)"
                    $httpErrorObj.FriendlyMessage = $rawErrorMessage.error.message
                }
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = "Received an unexpected response. The JSON could not be converted, error: [$($_.Exception.Message)]. Original error from web service: [$($ErrorObject.Exception.Message)]"
        }
        Write-Output $httpErrorObj
    }
}
#endregion

# Begin
try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($aRef))) {
        throw 'The account reference could not be found'
    }

    # Set authentication headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($config.UserName):$($config.Password)")))")
    $splatInvokeRestMethodProps = @{
        Headers     = $headers
        ContentType = 'application/json'
    }

    Write-Verbose "Verifying if a ServiceNow account for [$($p.DisplayName)] exists"
    try {
        $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user/$aRef"
        $splatInvokeRestMethodProps['Method'] = 'GET'
        $currentAccount = Invoke-RestMethod @splatInvokeRestMethodProps
    }
    catch {
        # A '400'bad request is returned if the entity cannot be found
        if ($_.Exception.Response.StatusCode -eq 400) {
            $currentAccount = $null
        }
        else {
            throw
        }
    }

    # Get the manager id from ServiceNow
    $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user?sysparm_query=$managerCorrelationProperty=$managerCorrelationValue"
    $splatInvokeRestMethodProps['Method'] = 'GET'
    $responseManagerUser = Invoke-RestMethod @splatInvokeRestMethodProps
    if (($responseManagerUser.result.sys_id | Measure-Object).Count -eq 0) {
        Write-Warning "No account found for manager where [$managerCorrelationProperty=$managerCorrelationValue]"
    }
    elseif (($responseManagerUser.result.sys_id | Measure-Object).Count -gt 1) {
        Write-Warning "Multiple accounts found for manager where [$managerCorrelationProperty=$managerCorrelationValue]. Please correct this so this is unique"
    }
    else {
        $account.manager = $responseManagerUser.result.sys_id
    }

    # Always compare the account against the current account in the target system
    $splatCompareProperties = @{
        ReferenceObject  = @($currentAccount.result.PSObject.Properties)
        DifferenceObject = @($account.PSObject.Properties)
    }
    $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
    if ($propertiesChanged) {
        $action = 'Update'
        $dryRunMessage = "Account property(s) required to update: [$($propertiesChanged.name -join ",")]"

        $changedPropertiesObject = @{}
        foreach ($property in $propertiesChanged) {
            $propertyName = $property.Name
            $propertyValue = $account.$propertyName

            $changedPropertiesObject.$propertyName = $propertyValue
        }
    }
    elseif (-not($propertiesChanged)) {
        $action = 'NoChanges'
        $dryRunMessage = 'No changes will be made to the account during enforcement'
    }
    elseif ($null -eq $currentAccount) {
        $action = 'NotFound'
        $dryRunMessage = "ServiceNow account for: [$($p.DisplayName)] not found. Possibly deleted."
    }
    Write-Verbose $dryRunMessage

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Update' {
                Write-Verbose "Updating ServiceNow account with accountReference: [$aRef]"
                $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user/$aRef"
                $splatInvokeRestMethodProps['Method'] = 'PUT'

                $body = $changedPropertiesObject | ConvertTo-Json
                $splatInvokeRestMethodProps['Body'] = [System.Text.Encoding]::UTF8.GetBytes($body)
                $null = Invoke-RestMethod @splatInvokeRestMethodProps

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'Update account was successful'
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Verbose "No changes to ServiceNow account with accountReference: [$aRef]"
                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                $success = $false
                $auditLogs.Add([PSCustomObject]@{
                        Message = "ServiceNow account for: [$($p.DisplayName)] not found. Possibly deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        $auditMessage = "Could not update ServiceNow account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update ServiceNow account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}