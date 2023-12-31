############################################
# HelloID-Conn-Prov-Target-ServiceNow-Create
#
# Version: 1.0.1
############################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$m = $manager | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Correlation values
$correlationProperty = "email" # Has to match the name of the unique identifier
$correlationValue = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName # Has to match the value of the unique identifier

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
    active          = $false
    locked_out      = $true
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
    # Verify if [account.email] has a value
    if ([string]::IsNullOrEmpty($($account.email))) {
        throw 'Mandatory attribute [account.email] is empty. Please make sure it is correctly mapped'
    }

    # Set authentication headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($config.UserName):$($config.Password)")))")
    $splatInvokeRestMethodProps = @{
        Headers     = $headers
        ContentType = 'application/json'
    }

    # Verify if a user must be either [created and correlated], [updated and correlated] or just [correlated]
    $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user?sysparm_query=$correlationProperty=$correlationValue"
    $splatInvokeRestMethodProps['Method'] = 'GET'
    $responseUser = Invoke-RestMethod @splatInvokeRestMethodProps
    if (($responseUser.result.sys_id | Measure-Object).Count -eq 0) {
        $action = 'Create-Correlate'
    }
    elseif (($responseUser.result.sys_id | Measure-Object).Count -gt 1) {
        throw "Multiple accounts found for person where [$correlationProperty=$correlationValue]. Please correct this so this is unique"
    }
    elseif (($responseUser.result.sys_id | Measure-Object).Count -eq 1 -and $($config.UpdatePersonOnCorrelate) -eq $true) {
        $action = 'Update-Correlate'
    }
    else {
        $action = 'Correlate'
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

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action ServiceNow account for: [$($p.DisplayName)], will be executed during enforcement"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                Write-Verbose 'Creating and correlating ServiceNow account'
                $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user"
                $splatInvokeRestMethodProps['Method'] = 'POST'

                $body = $account | ConvertTo-Json
                $splatInvokeRestMethodProps['Body'] = [System.Text.Encoding]::UTF8.GetBytes($body)
                $createUserResponse = Invoke-RestMethod @splatInvokeRestMethodProps
                $accountReference = $createUserResponse.result.sys_id
                break
            }

            'Update-Correlate' {
                Write-Verbose 'Setting account properties [locked_out, active] to the current values from ServiceNow'
                $account.locked_out = $responseUser.result.locked_out
                $account.active = $responseUser.result.active

                Write-Verbose 'Updating and correlating ServiceNow account'
                $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user/$($responseUser.result.sys_id)"
                $splatInvokeRestMethodProps['Method'] = 'PUT'

                $body = $account | ConvertTo-Json
                $splatInvokeRestMethodProps['Body'] = [System.Text.Encoding]::UTF8.GetBytes($body)
                $updateUserResponse = Invoke-RestMethod @splatInvokeRestMethodProps
                $accountReference = $updateUserResponse.result.sys_id
                break
            }

            'Correlate' {
                Write-Verbose 'Correlating ServiceNow account'
                $accountReference = $responseUser.result.sys_id
                break
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = "$action account was successful. AccountReference is: [$accountReference]"
                IsError = $false
            })
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        $auditMessage = "Could not $action ServiceNow account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not $action ServiceNow account. Error: $($ex.Exception.Message)"
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
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}