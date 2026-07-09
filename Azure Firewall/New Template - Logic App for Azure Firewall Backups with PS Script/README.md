# Azure Firewall Backup Solution

Automated, versioned backups of an **Azure Firewall Policy** (and all of its rule
collection groups) to a secure Storage account, with optional near-real-time
backups on every policy change, plus a guided restore + repoint workflow.

This folder contains two files:

| File | Purpose |
|------|---------|
| `backup-azfw-template-v3.json` | ARM template. Deploys all Azure resources (storage, Logic Apps, alert, action group). |
| `Deploy-FWBackup.ps1` | End-to-end deployer. Deploys the template, assigns RBAC, checks storage reachability, runs a baseline backup, and can restore. |

---

## What it does

- Exports the firewall **policy + rule collection groups** as an ARM template and
  stores it as a timestamped JSON blob: `backup-<firewallName>-<yyyy-MM-dd-HHmmss>.json`.
- Two backup triggers:
  - **Scheduled** (`<PlaybookName>`): runs on a recurrence (default every 3 days at 02:00 UTC).
  - **Write-triggered** (`<PlaybookName>-OnWrite`, optional): fires on **any** change to
    the firewall policy or its children via an Activity Log Alert.
- **Cooldown** on the write-trigger (default 5 min) prevents backup storms during bulk edits.
- **Retention**: a storage lifecycle rule auto-deletes backups older than `Retention_Days` (default 30).
- Uses **Managed Identity** end-to-end. No keys, no secrets. Storage is locked down
  (`defaultAction=Deny`, no public blob access, shared-key disabled).

---

## Architecture

```
                Activity Log Alert (optional, write trigger)
                scope = Policy Resource Group
                            |
                            v
                    Action Group (Logic App receiver)
                            |
  Recurrence timer         v
        |          <PlaybookName>-OnWrite  (Logic App, SystemAssigned MI)
        |                   |
        v                   |
  <PlaybookName> --------->-+--> exportTemplate on the POLICY's resource group
  (Logic App, MI)               (captures policy + all ruleCollectionGroups)
                                    |
                                    v
                        Rebuild RCGs with sequential dependsOn
                                    |
                                    v
                     PUT backup-<fw>-<timestamp>.json  --> Storage (firewall-backups)
```

### Resources deployed by the template

- `Microsoft.Storage/storageAccounts` (`Standard_LRS`, StorageV2, public access disabled)
  - blobService with 7-day soft-delete
  - container `firewall-backups`
  - lifecycle management policy `DeleteOldBackups` (retention)
- `Microsoft.Logic/workflows` `<PlaybookName>` (scheduled backup)
- `Microsoft.Logic/workflows` `<PlaybookName>-OnWrite` (write-triggered backup) *(only if `Enable_Write_Trigger=true`)*
- `Microsoft.Insights/actionGroups` `<PlaybookName>-AG` *(write trigger only)*
- `Microsoft.Insights/activityLogAlerts` `<PlaybookName>-WriteAlert` *(write trigger only)*

Both Logic Apps share the same backup logic (template variable `backupWorkflowActions`);
the OnWrite app adds the cooldown check.

---

## Cross-resource-group support (important)

The firewall, its policy, and the backup solution itself can all live in **different
resource groups**. This is common in hub-and-spoke designs.

The backup exports the policy by calling ARM `exportTemplate` **scoped to the policy's
own resource group** (`Policy_Resource_Group_Name`). This is required because an
RG-scoped `exportTemplate` only returns resources that live in that RG. Scoping the
export to the firewall's RG would silently drop the policy and all rule collection
groups when they live elsewhere, producing an empty/failed backup.

The deploy script grants **Contributor** to both Logic App identities on **both** the
firewall RG and the policy RG (deduplicated) so this works regardless of layout.

---

## Prerequisites

- Azure CLI (`az`) installed and logged in: `az login`.
- Rights to deploy resources **and** create role assignments (Owner or User Access
  Administrator on the relevant scopes).
- Windows PowerShell 5.1 or PowerShell 7+.

---

## Quick start

From this folder:

```powershell
# Uses the defaults baked into the script params (edit them or pass overrides)
.\Deploy-FWBackup.ps1

# Or specify everything explicitly:
.\Deploy-FWBackup.ps1 `
    -SubscriptionId        "<sub-guid>" `
    -ResourceGroup         "rg-hub-spoke-fw" `      # where the backup solution is deployed
    -FirewallResourceGroup "rg-hub-spoke-fw" `      # where the Azure Firewall lives
    -PolicyResourceGroup   "NetSecDemoShabaz" `     # where the Firewall Policy lives
    -StorageAccountName    "fwbackupsnew101" `
    -FirewallName          "azfw-hub" `
    -FirewallPolicyName    "fwpol-premium-alpineSkiHouse" `
    -PlaybookName          "BackUp-AzFW" `
    -EnableWriteTrigger    $true
```

The script is **idempotent** - safe to re-run. Existing role assignments are skipped.

---

## What the deploy script does (6 steps)

1. **Deploy** the ARM template (incremental) with your parameters.
2. **Assign roles** to both Logic App managed identities:
   - `Contributor` on the firewall RG and the policy RG.
   - `Storage Blob Data Contributor` on the storage account.
3. **Grant you** `Storage Blob Data Reader` on the storage account so you can list/read
   backups with your AAD identity.
4. **Check storage reachability**: if the storage account denies public access, it warns
   you and prints the exact `az storage account network-rule add` command to allow your
   IP. (The script does **not** modify the storage firewall for you.)
5. **Baseline backup**: optionally triggers the scheduled Logic App now and reports status.
6. **Restore (optional)**: restore a backup as a **new** policy and repoint a firewall.

---

## Restore

Run `Deploy-FWBackup.ps1` and answer **yes** at step 6, or run the restore flow on a
fresh invocation. You can restore from:

- a **local** backup `.json` you already downloaded, or
- the **latest** (or a chosen) blob listed from the storage container.

The restore:

1. Reads the backup template and finds the `firewallPolicies` name parameter.
2. Deploys it into `Policy_Resource_Group_Name` as a **new** policy
   (default name `<policy>-restored-<timestamp>`), so nothing is overwritten.
3. Optionally **repoints** an existing firewall to the new policy after explicit
   confirmation (this is a live write to the firewall).

> A backup captures the **policy and its rules** only; the firewall instance itself is
> intentionally excluded (it is infrastructure that references the policy). Restore
> recreates the policy and lets you attach it to a firewall.

4. If backup needs to be run separately, use command- 
 az deployment group create --resource-group <ExistingResourcegroup> --template-file <local path to downloaded backupfile>
---

## Parameters

### Template (`backup-azfw-template-v3.json`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Playbook_Name` | `BackUp-AzFW` | Base name; OnWrite app is `<name>-OnWrite`. |
| `Storage_Account_Name` | `fwbackups` | Storage account for backups. |
| `Firewall_Name` | (required) | Azure Firewall name (used for blob naming). |
| `Firewall_Policy_Name` | (required) | Firewall Policy to back up. |
| `Subscription_Id` | current sub | Subscription hosting firewall and policy. |
| `Firewall_Resource_Group_Name` | (required) | RG hosting the firewall. |
| `Policy_Resource_Group_Name` | = firewall RG | RG hosting the policy. Leave empty if same as firewall RG. |
| `Backup_Frequency_Days` | `3` | Recurrence interval (days). |
| `Backup_Start_Time` | `2024-01-01T02:00:00Z` | Recurrence start time (UTC). |
| `Retention_Days` | `30` | Days before backups are auto-deleted. |
| `Enable_Write_Trigger` | `false` | Deploy the change-triggered backup (alert + action group + OnWrite app). |
| `Write_Trigger_Cooldown_Minutes` | `5` | Min minutes between write-triggered backups. |

### Script (`Deploy-FWBackup.ps1`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SubscriptionId` | (env-specific) | Target subscription. |
| `ResourceGroup` | `rg-hub-spoke-fw` | RG where the solution is deployed. |
| `FirewallResourceGroup` | `rg-hub-spoke-fw` | RG hosting the firewall. Defaults to `ResourceGroup`. |
| `PolicyResourceGroup` | `NetSecDemoShabaz` | RG hosting the policy. Defaults to firewall RG. |
| `StorageAccountName` | `fwbackupsnew101` | Storage account. |
| `FirewallName` | `azfw-hub` | Firewall name. |
| `FirewallPolicyName` | `fwpol-premium-alpineSkiHouse` | Policy name. |
| `PlaybookName` | `BackUp-AzFW` | Logic App base name. |
| `EnableWriteTrigger` | `$true` | Deploy the write-triggered backup. |
| `TemplateFile` | `backup-azfw-template-v3.json` (next to the script) | ARM template path. |
| `BlobContainer` | `firewall-backups` | Backup container name. |

---

## Storage security notes

The storage account is deployed **locked down**:

- `publicNetworkAccess = Disabled`, `defaultAction = Deny`
- `allowBlobPublicAccess = false`, `allowSharedKeyAccess = false`, TLS 1.2 min
- `bypass = AzureServices` so the Logic App managed identities can still write.

Backups **will still be written** over the trusted managed-identity path. However, you
will **not** be able to list/download blobs from your machine or the portal until your
IP or network is allowed. Add your IP:

```powershell
az storage account network-rule add --account-name <storage> -g <rg> --ip-address <your-ip>
```

Listing/downloading uses AAD (`--auth-mode login`), not account keys.

---

## Verify a backup

```powershell
# List backups (requires your IP allowed + Storage Blob Data Reader)
az storage blob list --account-name <storage> --container-name firewall-backups `
    --auth-mode login --query "sort_by([].{name:name,modified:properties.lastModified},&name)[-5:]" -o table

# Check the latest Logic App run
az rest --method get `
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/BackUp-AzFW/runs?api-version=2019-05-01" `
  --query "value[0].{status:properties.status,start:properties.startTime}" -o table
```

A healthy backup blob contains 1 `Microsoft.Network/firewallPolicies` resource plus one
`.../ruleCollectionGroups` resource per RCG, chained with sequential `dependsOn`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Run failed, `Extract_Policy_Param` error `replace ... type Null` | Export returned no rule collection groups (policy was in a different RG than the export scope, or policy has 0 RCGs). | Ensure `Policy_Resource_Group_Name` is correct. Current template exports from the policy RG and guards the zero-RCG case. |
| Backup blob written but missing rules | Export scoped to the wrong RG. | Confirm the export URI uses `policyResourceGroup` (fixed in this template). |
| Can't see backups in portal/CLI | Storage firewall blocks your IP. | Add your IP (see Storage security notes). |
| Role grant failed | Signed-in user lacks Owner/UAA. | Have an admin assign the roles, or re-run as a privileged user. |
| OnWrite app didn't fire | `Enable_Write_Trigger` was false, or the change was outside the policy RG scope. | Redeploy with `Enable_Write_Trigger=$true`; alert scope is the policy RG. |

---

## Notes

- Editing the **live** Logic Apps in the portal will be **overwritten** on the next
  `Deploy-FWBackup.ps1` run. Make durable changes in `backup-azfw-template-v3.json`.
- The template is UTF-8 (no BOM) with CRLF line endings; keep that encoding when editing.
