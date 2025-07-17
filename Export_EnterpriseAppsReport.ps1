# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All", "AuditLog.Read.All", "User.Read.All", "Group.Read.All", "Reports.Read.All"

# Start timer
$startTime = Get-Date
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# Step 1 – Get all Enterprise Applications
Write-Host "[+] Retrieving Enterprise Applications..."
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

Write-Host "    → Retrieved $($allApps.Count) apps."

# Step 2 – Retrieve Sign-In Activity
Write-Host "[+] Retrieving Sign-In Activity..."
$signInData = @()
$uri = "https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities"

do {
    $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
    $signInData += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)

Write-Host "    → Retrieved $($signInData.Count) sign-in entries."

# Step 3 – Build batch requests for Owners and Assignments
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

# Step 4 – Function to send batch requests
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

# Step 5 – Execute batch
Write-Host "[+] Sending batched requests..."
$responses = Send-MgGraphBatchRequests -requests $requests
Write-Host "    → Received $($responses.Count) responses."

# Step 6 – Compile Report
Write-Host "[+] Compiling report..."
$rows = foreach ($app in $allApps) {
    $id = $app.id
    $ownerResp = $responses | Where-Object { $_.requestid -eq "${id}_owners" }
    $assignResp = $responses | Where-Object { $_.requestid -eq "${id}_assignments" }

    # Owners
    $owners = (($ownerResp.body.value | Where-Object { $_.userPrincipalName }) | ForEach-Object { $_.userPrincipalName }) -join ", "

    # App Role Assignments
    $assignments = @()
    if ($assignResp.body.value) {
        foreach ($entry in $assignResp.body.value) {
            $assignments += "$($entry.principalDisplayName) [$($entry.principalType)]"
        }
    }
    $assignedList = $assignments -join ", "

    # Sign-In Activity (correct nested structure)
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

    # Report Row
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

# Step 7 – Export CSV
$output = "EnterpriseApps_Report_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
$rows | Sort-Object DisplayName | Export-Csv -Path $output -NoTypeInformation -Encoding UTF8

# Final Summary
$timer.Stop()
Write-Host "✔ Report saved to: $output"
Write-Host "🕒 Duration: $($timer.Elapsed.ToString())"
