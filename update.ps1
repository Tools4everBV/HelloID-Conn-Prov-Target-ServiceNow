#################################################
# HelloID-Conn-Prov-Target-ServiceNow-Update
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
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    # Set authentication headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($actionContext.Configuration.UserName):$($actionContext.Configuration.Password)")))")

    Write-Information 'Verifying if a ServiceNow account exists'
    try {
        $splatGetAccount = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($actionContext.References.Account)"
            Method  = 'GET'
            Headers = $headers
        }
        $correlatedAccount = (Invoke-RestMethod @splatGetAccount).result
    }
    catch {
        # A '400'bad request is returned if the entity cannot be found
        if ($_.Exception.Response.StatusCode -eq 400) {
            $correlatedAccount = $null
        }
        else {
            throw
        }
    }

    $actions = @()
    # Verify if the manager must be updated
    if ($null -ne $correlatedAccount.manager.value -and $correlatedAccount.manager.value -match '^[a-f0-9]{32}$') {
        $splatGetManager = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($correlatedAccount.manager.value)"
            Method  = 'GET'
            Headers = $headers
        }
        $linkedManager = (Invoke-RestMethod @splatGetManager).result
        if ($linkedManager.email -ne $personContext.PrimaryManager.Email){
            $splatGetManager = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user?sysparm_query=email=$($personContext.PrimaryManager.Email)"
                Method  = 'GET'
                Headers = $headers
            }
            $manager = (Invoke-RestMethod @splatGetManager).result
            if (($manager | Measure-Object).Count -eq 1){
                Write-Information "Found manager: [$($manager.name)] with id: [$($manager.sys_id)]"
                $actions += 'UpdateManager'
            } else {
                Write-Warning "Could not find manager: [$($manager.name)]. manager will not be updated"
            }
        }
    }

    # Verify if the location must be updated
    if ($null -ne $correlatedAccount.location.value -and $correlatedAccount.location.value -match '^[a-f0-9]{32}$') {
        $splatGetLocation = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_location/$($correlatedAccount.location.value)"
            Method  = 'GET'
            Headers = $headers
        }
        $linkedLocation = (Invoke-RestMethod @splatGetLocation).result
        if ($linkedLocation.name -ne $actionContext.Data.location){
            $splatGetLocation = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_location?sysparm_query=name=$($actionContext.Data.location)"
                Method  = 'GET'
                Headers = $headers
            }
            $location = (Invoke-RestMethod @splatGetLocation).result
            if (($location | Measure-Object).Count -eq 1){
                Write-Information "Found location: [$($location.name)] with id: [$($location.sys_id)]"
                $actions += 'UpdateLocation'
            } else {
                Write-Warning "Could not find location: [$($location.name)]. Location will not be updated"
            }
        } elseif ($null -eq $actionContext.Data.location){
            $actionContext.Data.location = ''
        }
    }

    # Verify if the department must be updated
    if ($null -ne $correlatedAccount.department.value -and $correlatedAccount.department.value -match '^[a-f0-9]{32}$') {
        $splatGetDepartment = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_department/$($correlatedAccount.department.value)"
            Method  = 'GET'
            Headers = $headers
        }
        $linkedDepartment = (Invoke-RestMethod @splatGetDepartment).result
        if ($linkedDepartment.name -ne $actionContext.Data.department){
            $splatGetDepartment = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/cmn_department?sysparm_query=name=$($actionContext.Data.department)"
                Method  = 'GET'
                Headers = $headers
            }
            $department = (Invoke-RestMethod @splatGetDepartment).result
            if (($department | Measure-Object).Count -eq 1){
                Write-Information "Found department: [$($department.name)] with id: [$($department.sys_id)]"
                $actions += 'UpdateDepartment'
            } else {
                Write-Warning "Could not find department: [$($department.name)]. department will not be updated"
            }
        }elseif ($null -eq $actionContext.Data.department){
            $actionContext.Data.department = ''
        }
    }

    if ($null -ne $correlatedAccount){
        # Filter empty and null values from the actionContext.Data
        $actionContextDataFiltered = [PSCustomObject]@{}
        $actionContext.Data.PSObject.Properties.Where({ $_.Value -ne "" -and $_.Value -ne $null }) | ForEach-Object { $actionContextDataFiltered | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value }

        # Filter out the department and location fields from actionContextDataFiltered
        $actionContextDataFiltered.PSObject.Properties.Remove('location')
        $actionContextDataFiltered.PSObject.Properties.Remove('department')

        # Always compare the account against the current account in target system
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount.PSObject.Properties.Where({ $_.MemberType -eq 'NoteProperty' }))
            DifferenceObject = @($actionContextDataFiltered.PSObject.Properties)
        }
        $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
        if ($propertiesChanged) {
            $actions += 'UpdateAccount'

            $changedPropertiesObject = @{}
            foreach ($property in $propertiesChanged) {
                $propertyName = $property.Name
                $propertyValue = $actionContextDataFiltered.$propertyName

                $changedPropertiesObject.$propertyName = $propertyValue
            }
        }
        else {
            $actions += 'NoChanges'
        }
    } elseif ($null -eq $correlatedAccount)  {
        $actions += 'NotFound'
    }

    # Process
    foreach ($action in $actions){
        switch ($action) {
            'UpdateAccount' {
                Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating ServiceNow account with accountReference: [$($actionContext.References.Account)]"
                    $splatUpdateAccount = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($actionContext.References.Account)"
                        Method  = 'PUT'
                        Body    = [System.Text.Encoding]::UTF8.GetBytes(($changedPropertiesObject | ConvertTo-Json))
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatUpdateAccount
                } else {
                    Write-Information "[DryRun] Update ServiceNow account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update ServiceNow account was successful. Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                        IsError = $false
                    })
                break
            }

            'UpdateManager' {
                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating manager to: [$($personContext.PrimaryManager.Email)] for ServiceNow account with accountReference: [$($actionContext.References.Account)]"
                    $splatUpdateAccountDepartment = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($actionContext.References.Account)"
                        Method  = 'PUT'
                        Body    = @{
                            manager = $manager.sys_id
                        } | ConvertTo-Json
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatUpdateAccountDepartment
                } else {
                    Write-Information "[DryRun] Update manager for ServiceNow account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update manager for ServiceNow account was successful. department set to: [$($personContext.PrimaryManager.Email)] with sys_id: [$($manager.sys_id)]"
                        IsError = $false
                    })
                break
            }

            'UpdateLocation' {
                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating location to: [$($actionContext.Data.location)] for ServiceNow account with accountReference: [$($actionContext.References.Account)]"
                    $splatUpdateAccountLocation = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($actionContext.References.Account)"
                        Method  = 'PUT'
                        Body    = @{
                            location = $actionContext.Data.location
                        } | ConvertTo-Json
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatUpdateAccountLocation
                } else {
                    Write-Information "[DryRun] Update location for ServiceNow account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update location for ServiceNow account was successful. Location set to: [$($actionContext.Data.location)] with sys_id: [$($location.sys_id)]"
                        IsError = $false
                    })
                break
            }

            'UpdateDepartment' {
                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating department to: [$($actionContext.Data.department)] for ServiceNow account with accountReference: [$($actionContext.References.Account)]"
                    $splatUpdateAccountDepartment = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/now/table/sys_user/$($actionContext.References.Account)"
                        Method  = 'PUT'
                        Body    = @{
                            department = $actionContext.Data.department
                        } | ConvertTo-Json
                        Headers = $headers
                    }
                    $null = Invoke-RestMethod @splatUpdateAccountDepartment
                } else {
                    Write-Information "[DryRun] Update department for ServiceNow account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update department for ServiceNow account was successful. department set to: [$($actionContext.Data.department)] with sys_id: [$($department.sys_id)]"
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Information "No changes to ServiceNow account with accountReference: [$($actionContext.References.Account)]"
                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                Write-Information "ServiceNow account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                $outputContext.Success = $false
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "ServiceNow account with accountReference: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
} catch {
    $outputContext.Success  = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-ServiceNowError -ErrorObject $ex
        $auditMessage = "Could not update ServiceNow account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update ServiceNow account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
