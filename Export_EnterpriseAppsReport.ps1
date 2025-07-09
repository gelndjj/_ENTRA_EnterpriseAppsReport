# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All", "AuditLog.Read.All", "User.Read.All", "Group.Read.All"

# Start timer
$startTime = Get-Date
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# Step 1 – Get all Enterprise Applications (from /beta for signInActivity)
Write-Host "[+] Retrieving Enterprise Applications..."
$uri = "https://graph.microsoft.com/beta/servicePrincipals?`$select=id,displayName,appId,homepage,publisherName,tags,createdDateTime,appRoleAssignmentRequired,accountEnabled,signInActivity,oauth2PermissionScopes,appRoles,web"
$apps = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
$allApps = @()

do {
    $allApps += $apps.value
    $next = $apps.'@odata.nextLink'
    if ($next) {
        $apps = Invoke-MgGraphRequest -Uri $next -Method GET -OutputType PSObject
    }
} while ($next)

Write-Host "    → Retrieved $($allApps.Count) apps."

# Step 2 – Build batch requests (Owners and App Role Assignments)
Write-Host "[+] Building batch requests..."
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

# Step 3 – Send batch requests function
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

# Step 4 – Execute batches
Write-Host "[+] Sending batched requests..."
$responses = Send-MgGraphBatchRequests -requests $requests
Write-Host "    → Received $($responses.Count) responses."

# Step 5 – Compile report
Write-Host "[+] Compiling report..."
$rows = foreach ($app in $allApps) {
    $id = $app.id
    $ownerResp = $responses | Where-Object { $_.requestid -eq "${id}_owners" }
    $assignResp = $responses | Where-Object { $_.requestid -eq "${id}_assignments" }

    # Owners
    $owners = (($ownerResp.body.value | Where-Object { $_.userPrincipalName }) | ForEach-Object { $_.userPrincipalName }) -join ", "

    # Assigned Users and Groups
    $assignments = @()
    if ($assignResp.body.value) {
        foreach ($entry in $assignResp.body.value) {
            $assignments += "$($entry.principalDisplayName) [$($entry.principalType)]"
        }
    }
    $assignedList = $assignments -join ", "

    # SignInActivity Status
    $signInTime = $app.signInActivity.lastSignInDateTime
    $signInStatus = if ($signInTime) { "Active" } else { "Never Signed In" }

    [PSCustomObject]@{
        DisplayName               = $app.displayName
        ObjectId                  = $app.id
        AppId                     = $app.appId
        Homepage                  = $app.homepage
        PublisherName             = $app.publisherName
        Tags                      = ($app.tags -join ", ")
        AccountEnabled            = $app.accountEnabled
        AppRoleAssignmentRequired = $app.appRoleAssignmentRequired
        CreatedDateTime           = $app.createdDateTime
        OwnersUPNs                = $owners
        AssignedUsersAndGroups    = $assignedList
        SignInActivity            = $signInTime
        SignInStatus              = $signInStatus
        Oauth2PermissionScopes    = (($app.oauth2PermissionScopes | ForEach-Object { $_.value }) -join "; ")
        AppRoles                  = (($app.appRoles | ForEach-Object { $_.value }) -join "; ")
    }
}

# Step 6 – Export to CSV
$output = "EnterpriseApps_Report_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
$rows | Sort-Object DisplayName | Export-Csv -Path $output -NoTypeInformation -Encoding UTF8

# Final summary
$timer.Stop()
Write-Host "✔ Report saved to: $output"
Write-Host "🕒 Duration: $($timer.Elapsed.ToString())"
