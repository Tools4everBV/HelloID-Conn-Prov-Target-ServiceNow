#############################################
# HelloID-Conn-Prov-Target-ServiceNow-Disable
#
# Version: 1.0.0
#############################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

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
                $httpErrorObj.ErrorDetails =  "Error: $($rawErrorMessage.error.message), details: $($rawErrorMessage.error.detail), status: $($rawErrorMessage.status)"
                $httpErrorObj.FriendlyMessage =  $rawErrorMessage.error.message
            } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if($null -ne $streamReaderResponse){
                    $rawErrorMessage = ($streamReaderResponse | ConvertFrom-Json)
                    $httpErrorObj.ErrorDetails =  "Error: $($rawErrorMessage.error.message), details: $($rawErrorMessage.error.detail), status: $($rawErrorMessage.status)"
                    $httpErrorObj.FriendlyMessage =  $rawErrorMessage.error.message
                }
            }
        } catch {
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
        $responseUser = Invoke-RestMethod @splatInvokeRestMethodProps
    } catch {
        # A '400'bad request is returned if the entity cannot be found
        if ($_.Exception.Response.StatusCode -eq 400) {
            $responseUser = $null
        }
        else {
            throw
        }
    }

    Write-Verbose "Verifying if a ServiceNow account for [$($p.DisplayName)] exists"
    if ($responseUser.result.sys_id){
        $action = 'Found'
        $dryRunMessage = "Disable ServiceNow account for: [$($p.DisplayName)] will be executed during enforcement"
    } elseif($null -eq $responseUser) {
        $action = 'NotFound'
        $dryRunMessage = "ServiceNow account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
    }
    Write-Verbose $dryRunMessage

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action){
            'Found' {
                Write-Verbose "Disable ServiceNow account with accountReference: [$aRef]"
                $splatInvokeRestMethodProps['Uri'] = "$($config.BaseUrl)/api/now/table/sys_user/$aRef"
                $splatInvokeRestMethodProps['Method'] = 'PUT'
                $splatInvokeRestMethodProps['Body'] = @{ active = $false } | ConvertTo-Json
                $null = Invoke-RestMethod @splatInvokeRestMethodProps

                $auditLogs.Add([PSCustomObject]@{
                    Message = 'Disable account was successful'
                    IsError = $false
                })
                break
            }

            'NotFound' {
                $auditLogs.Add([PSCustomObject]@{
                    Message = "ServiceNow account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
                    IsError = $false
                })
                break
            }
        }

        $success = $true
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        $auditMessage = "Could not disable ServiceNow account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not disable ServiceNow account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
# End
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
