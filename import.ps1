#################################################
# HelloID-Conn-Prov-Target-ServiceNow-Import
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
    Write-Information 'Starting ServiceNow account entitlement import'

    # Set authentication headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($actionContext.Configuration.UserName):$($actionContext.Configuration.Password)")))")

    # Get Accounts
    $importedAccounts = [System.Collections.ArrayList]::new()

    $take = 1000
    $skip = 0
    $moreRecords = $true

    while ($moreRecords) {
        $splatGetAccounts = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user?sysparm_limit=$take&sysparm_offset=$skip"
            Method  = 'GET'
            Headers = $headers
        }
    
        $GetResponse = (Invoke-RestMethod @splatGetAccounts)

        foreach ($record in $GetResponse.result) {
            [void]$importedAccounts.Add($record)
        }

        if ($GetResponse.result.Count -lt $take) {
            $moreRecords = $false
        }
        else {
            $skip += $take
        }
    }
    
    foreach ($importedAccount in $importedAccounts) {
        $enabled = $false

        if ($importedAccount.active -eq $true) {
            $enabled = $true
        }

        # Set UserName if missing
        if ([string]::IsNullOrEmpty($importedAccount.user_name)) {
            $importedAccount.user_name = $importedAccount.sys_id
        }

        # Set DisplayName if missing
        if ([string]::IsNullOrEmpty($importedAccount.name)) {
            $importedAccount.name = $importedAccount.user_name
        }

        # Return the result
        Write-Output @{
            AccountReference = $importedAccount.sys_id
            DisplayName      = $importedAccount.name
            UserName         = $importedAccount.user_name
            Enabled          = $enabled
            Data             = $importedAccount
        }
    }
    
    Write-Information 'ServiceNow account entitlement import completed'
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        Write-Error "Could not import ServiceNow account entitlements. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        Write-Error "Could not import ServiceNow account entitlements. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
}
