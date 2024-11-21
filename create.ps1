#################################################
# HelloID-Conn-Prov-Target-ServiceNow-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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

try {
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    # Set authentication headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($actionContext.Configuration.UserName):$($actionContext.Configuration.Password)")))")

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        $splatGetAccount = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user?sysparm_query=$($correlationField)=$($correlationValue)"
            Method  = 'GET'
            Headers = $headers
        }
        $correlatedAccount = (Invoke-RestMethod @splatGetAccount).result
        if (($correlatedAccount | Measure-Object).Count -eq 0){
            $action = 'CreateAccount'
        } elseif (($correlatedAccount | Measure-Object).Count -eq 1){
            $action = 'CorrelateAccount'
        } elseif (($correlatedAccount | Measure-Object).Count -gt 1){
            throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
        }
    }

    # Lookup the user manager
    if ($null -ne $personContext.Person.PrimaryManager.email){
        $splatGetManagerAccount = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user?sysparm_query=email=$($personContext.Person.PrimaryManager.email)"
            Method  = 'GET'
            Headers = $headers
        }
        $managerAccount = (Invoke-RestMethod @splatGetManagerAccount).result
        if (($managerAccount | Measure-Object).Count -eq 1){
            Write-Information "Found manager: [$($managerAccount.name)] with id: [$($managerAccount.sys_id)]"
            $actionContext.Data['Manager'] = $managerAccount.result.sys_id
        } else {
            Write-Warning "Could not find manager with email: [$($personContext.Person.PrimaryManager.email)]"
            $actionContext.Data.remove('manager')
        }
    }

    # Lookup the department
    if ($null -ne $actionContext.Data.department){
        $splatGetDepartment = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_department?sysparm_query=name=$($actionContext.Data.department)"
            Method  = 'GET'
            Headers = $headers
        }
        $department = (Invoke-RestMethod @splatGetDepartment).result
        if (($department | Measure-Object).Count -eq 1){
            Write-Information "Found department: [$($department.name)] with id: [$($department.sys_id)]"
        } else {
            Write-Warning "Could not find department: [$($department.name)]"
            $actionContext.Data.remove('department')
        }
    }

    # Lookup the location
    if ($null -ne $actionContext.Data.location){
        $splatGetLocation = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_location?sysparm_query=name=$($actionContext.Data.location)"
            Method  = 'GET'
            Headers = $headers
        }
        $location = (Invoke-RestMethod @splatGetLocation).result
        if (($location | Measure-Object).Count -eq 1){
            Write-Information "Found location: [$($location.name)] with id: [$($location.sys_id)]"
        } else {
            Write-Warning "Could not find location: [$($location.name)]"
            $actionContext.Data.remove('location')
        }
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating ServiceNow account'
                $actionContext.Data | Add-Member -MemberType NoteProperty -Name 'locked_out' -Value $true
                $actionContext.Data | Add-Member -MemberType NoteProperty -Name 'active' -Value $false

                $splatCreateAccount = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user"
                    Method      = 'POST'
                    Body        = [System.Text.Encoding]::UTF8.GetBytes(($actionContext.Data | ConvertTo-Json))
                    ContentType = 'application/json'
                    Headers     = $headers
                }
                $createdAccount = Invoke-RestMethod @splatCreateAccount
                $outputContext.AccountReference = $createdAccount.result.sys_id
            } else {
                Write-Information '[DryRun] Create and correlate ServiceNow account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating ServiceNow account'
            $outputContext.Data = $correlatedAccount
            $outputContext.AccountReference = $correlatedAccount.result.sys_id
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        $auditMessage = "Could not create or correlate ServiceNow account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create or correlate ServiceNow account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}