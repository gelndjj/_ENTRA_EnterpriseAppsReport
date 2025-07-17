# Enterprise Applications Report

PowerShell script to export **Enterprise Applications (Service Principals)** from Microsoft Entra ID, including owners, assigned users/groups, sign-in activity, OAuth2 scopes, app roles, and sign-in status.

## ⚙️ Prerequisites

- PowerShell 7.x (cross‑platform) or Windows PowerShell 5.1
- Installed modules:
```powershell
  Install-Module Microsoft.Graph -Scope CurrentUser
```

## ✅ Graph API Permissions

Ensure the running user (delegated) or app (app‑only) has all of these:
1. Application.Read.All
2. Directory.Read.All
3. AuditLog.Read.All (for sign‑in activity)
4. User.Read.All
5. Group.Read.All

If using delegated permissions: user must be in a role such as Global Reader, Reports Reader, or Security Reader

## 🚀 Usage

``` pwsh
git clone https://github.com/your-org/_ENTRA_EnterpriseAppsReport.git
cd EnterpriseAppsReport/scripts
pwsh .\Export-EnterpriseAppsReport.ps1
```
This will generate a CSV file named like: EnterpriseApps_Report_20250709_1200.csv

## 📋 Output Columns

DisplayName, ObjectId, AppId
Homepage, PublisherName, Tags, AccountEnabled, AppRoleAssignmentRequired
CreatedDateTime, OwnersUPNs
AssignedUsersAndGroups (list of UPNs or group names)
SignInActivity (last sign‑in timestamp)
SignInStatus (Active or Never Signed In)
Oauth2PermissionScopes, AppRoles

## ⚠️ Notes

SignInActivity is in Microsoft Graph Beta, and may take up to 24 hours to populate.
OAuth2PermissionScopes and AppRoles fields will be empty if not configured on the app.

## 🛠️ Extensibility

Filter custom apps or split results into separate CSVs.
Add scheduled runs via GitHub Actions or Azure Automation.


## ☁️ Azure Automation Runbook

You can schedule this report to run daily or weekly in Azure Automation with a Managed Identity and upload the CSV to SharePoint.

### Required Setup
Import these modules into your Automation Account:
  Microsoft.Graph
  PnP.PowerShell
  Assign Managed Identity permissions:
  Microsoft Graph (Application):
  Application.Read.All, Directory.Read.All, User.Read.All, Group.Read.All, AuditLog.Read.All, Reports.Read.All
  SharePoint Contributor access on the destination document library

### Customization
Update this line to match your SharePoint site and folder:

```pwsh
$sharePointSiteUrl = "https://<YourTenant>.sharepoint.com/sites/<YourSiteName>"
$sharePointLibraryPath = "Shared Documents/Reporting/Entra"
```

## Runbook Features

Authenticates using Managed Identity
Retrieves and joins:
Enterprise Apps (service principals)
App owners and assignments
Sign-in activity (interactive + non-interactive)
Generates a full CSV report
Uploads directly to your SharePoint folder

#### ➡️ See the Runbook_Template-EnterpriseAppReport.ps1 script.
