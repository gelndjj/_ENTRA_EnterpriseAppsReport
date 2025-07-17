<#
.SYNOPSIS
    Runbook to generate an Enterprise Applications Report with sign-in activity and upload it to SharePoint.

.REQUIREMENTS
    - Azure Automation Account with Managed Identity
    - Graph API Permissions (Application):
        • Application.Read.All
        • Directory.Read.All
        • AuditLog.Read.All
        • Group.Read.All
        • User.Read.All
        • Reports.Read.All
    - SharePoint Contributor role on target library
    - Modules imported: Microsoft.Graph, PnP.PowerShell
#>

# STEP 1 – Connect to Microsoft Graph via Managed Identity
Connect-MgGraph -Identity -NoWelcome
Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" | Out-Null  # ensure token cache

# STEP 2 – Connect to SharePoint via Managed Identity
$sharePointSiteUrl = "https://<YourTenant>.sharepoint.com/sites/<YourSiteName>"
$sharePointLibraryPath = "Shared Documents/Reporting/Entra"

Connect-PnPOnline -Url $sharePointSiteUrl -ManagedIdentity

# STEP 3 – Timer
$startTime = Get-Date
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# STEP 4 – Get Enterprise Apps
Write-Output "[+] Retrieving Enterprise Applications..."
$uri = "https://graph.microsoft.com/beta/servicePrincipals?`$select=id,displayName,appId,homepage,publisherName,tags,createdDateTime,appRoleAssignmentRequired,accountEnabled,oauth2PermissionScopes,appRoles,web"
$apps = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
$allApps = @()

do {
    $allApps += $apps.value
    $next = $apps.'@odata.nextLink'
    if ($next) {
        $apps = Invoke-MgGraphRequest -Uri $next -Method GET -OutputType PSObject
    }
} while ($next)

# STEP 5 – Get Sign-In Activity
Write-Output "[+] Retrieving Sign-In Activity..."
$signInData = @()
$uri = "https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities"

do {
    $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
    $signInData += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)

# STEP 6 – Build Batch Requests
$requests = [System.Collections.Generic.List[object]]::new()
foreach ($app in $allApps) {
    $requests.Add(@{
        id     = "$($app.id)_owners"
        method = "GET"
        url    = "/servicePrincipals/$($app.id)/owners?`$select=userPrincipalName"
    })
    $requests.Add(@{
        id     = "$($app.id)_assignments"
        method = "GET"
        url    = "/servicePrincipals/$($app.id)/appRoleAssignedTo?`$select=principalDisplayName,principalType"
    })
}

# STEP 7 – Send Batch Requests
function Send-MgGraphBatchRequests {
    param (
        [Parameter(Mandatory)] $requests,
        [int] $batchSize = 20
    )
    $responses = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    for ($i = 0; $i -lt $requests.Count; $i += $batchSize) {
        $batch = $requests[$i..([Math]::Min($i + $batchSize - 1, $requests.Count - 1))]
        $body = @{ requests = $batch } | ConvertTo-Json -Depth 5
        $result = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/`$batch" -Body $body -ContentType "application/json"
        foreach ($r in $result.responses) {
            $responses.Add([pscustomobject]@{
                requestid = $r.id
                body      = $r.body
                error     = $r.error
            })
        }
    }
    return $responses
}

$responses = Send-MgGraphBatchRequests -requests $requests

# STEP 8 – Compile CSV Rows
$rows = foreach ($app in $allApps) {
    $id = $app.id
    $ownerResp = $responses | Where-Object { $_.requestid -eq "${id}_owners" }
    $assignResp = $responses | Where-Object { $_.requestid -eq "${id}_assignments" }

    $owners = (($ownerResp.body.value | Where-Object { $_.userPrincipalName }) | ForEach-Object { $_.userPrincipalName }) -join ", "

    $assignments = @()
    if ($assignResp.body.value) {
        foreach ($entry in $assignResp.body.value) {
            $assignments += "$($entry.principalDisplayName) [$($entry.principalType)]"
        }
    }
    $assignedList = $assignments -join ", "

    $signinEntry = $signInData | Where-Object { $_.appId -eq $app.appId }

    $interactiveSignIn       = $signinEntry.lastSignInActivity.lastSignInDateTime
    $clientCredsSignIn       = $signinEntry.applicationAuthenticationClientSignInActivity.lastSignInDateTime
    $delegatedClientSignIn   = $signinEntry.delegatedClientSignInActivity.lastSignInDateTime
    $delegatedResourceSignIn = $signinEntry.delegatedResourceSignInActivity.lastSignInDateTime

    $signInStatus = if ($interactiveSignIn -or $clientCredsSignIn -or $delegatedClientSignIn -or $delegatedResourceSignIn) {
        "Active"
    } else {
        "Never Signed In"
    }

    [PSCustomObject]@{
        DisplayName                     = $app.displayName
        ObjectId                        = $app.id
        AppId                           = $app.appId
        Homepage                        = $app.homepage
        PublisherName                   = $app.publisherName
        Tags                            = ($app.tags -join ", ")
        AccountEnabled                  = $app.accountEnabled
        AppRoleAssignmentRequired       = $app.appRoleAssignmentRequired
        CreatedDateTime                 = $app.createdDateTime
        OwnersUPNs                      = $owners
        AssignedUsersAndGroups          = $assignedList
        SignInStatus                    = $signInStatus
        LastInteractiveSignIn           = $interactiveSignIn
        LastClientCredentialSignIn      = $clientCredsSignIn
        LastDelegatedClientSignIn       = $delegatedClientSignIn
        LastDelegatedResourceSignIn     = $delegatedResourceSignIn
        Oauth2PermissionScopes          = (($app.oauth2PermissionScopes | ForEach-Object { $_.value }) -join "; ")
        AppRoles                        = (($app.appRoles | ForEach-Object { $_.value }) -join "; ")
    }
}

# STEP 9 – Save CSV and Upload to SharePoint
$tempPath = "$env:TEMP\EnterpriseApps_Report_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
$rows | Sort-Object DisplayName | Export-Csv -Path $tempPath -NoTypeInformation -Encoding UTF8

$fileName = Split-Path $tempPath -Leaf
Add-PnPFile -Path $tempPath -Folder $sharePointLibraryPath -NewFileName $fileName -Values @{}

Write-Output "Report uploaded to SharePoint: $sharePointLibraryPath/$fileName"

# STEP 10 – End
$timer.Stop()
Write-Output "Duration: $($timer.Elapsed.ToString())"
