<#
.SYNOPSIS
    End-to-end deployer for the Azure Firewall Backup solution.

.DESCRIPTION
    One script that:
      1. Deploys the AzFW backup ARM template (recurrence + optional write-trigger).
      2. Assigns the required RBAC roles to BOTH Logic App managed identities.
      3. Grants the signed-in USER data-plane read access so they can list backups.
      4. Detects storage-account network rules and offers to add the caller's public IP
         (with a clear alert that the storage must be reachable from your IP/network to
         see the backups in the blob container).
      5. Prompts to run a baseline backup immediately.
      6. Optionally RESTORES the latest backup as a NEW named firewall policy and
         repoints an existing firewall to it (guarded, with explicit confirmations).

.NOTES
    Requires: Azure CLI (az) logged in with rights to deploy + assign roles.
    Idempotent: safe to re-run. Role assignments that already exist are skipped.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId          = "",
    [string]$ResourceGroup           = "",
    [string]$FirewallResourceGroup   = "",
    [string]$PolicyResourceGroup     = "",
    [string]$StorageAccountName      = "",
    [string]$FirewallName            = "",
    [string]$FirewallPolicyName      = "",
    [string]$PlaybookName            = "",
    [bool]  $EnableWriteTrigger      = $true,
    [string]$TemplateFile            = "",
    [string]$BlobContainer           = ""
)

$ErrorActionPreference = "Stop"

# Resolve script directory robustly (works via -File, dot-source, or interactive)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($TemplateFile)) {
    $TemplateFile = Join-Path $scriptDir "backup-azfw-template-v3.json"
}

# Normalize inputs: strip stray leading/trailing whitespace so values pasted with
# accidental spaces don't corrupt az lookups or ARM scope/resourceId strings.
foreach ($p in 'SubscriptionId','ResourceGroup','FirewallResourceGroup','PolicyResourceGroup',
                'StorageAccountName','FirewallName','FirewallPolicyName','PlaybookName',
                'TemplateFile','BlobContainer') {
    $v = Get-Variable -Name $p -ValueOnly -ErrorAction SilentlyContinue
    if ($v -is [string]) { Set-Variable -Name $p -Value ($v.Trim()) }
}

# Resolve resource groups. The firewall and its policy can live in different RGs
# (and in a different RG than where this backup solution is deployed).
#   $ResourceGroup         -> deployment RG (Logic Apps, storage, alert, action group)
#   $FirewallResourceGroup -> RG hosting the Azure Firewall (defaults to deployment RG)
#   $PolicyResourceGroup   -> RG hosting the Firewall Policy (defaults to firewall RG)
if ([string]::IsNullOrWhiteSpace($FirewallResourceGroup)) { $FirewallResourceGroup = $ResourceGroup }
if ([string]::IsNullOrWhiteSpace($PolicyResourceGroup))   { $PolicyResourceGroup   = $FirewallResourceGroup }

# ----------------------------- helpers -----------------------------
function Write-Step  ($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok    ($m){ Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-Warn2 ($m){ Write-Host "  [!!]  $m" -ForegroundColor Yellow }
function Write-Info  ($m){ Write-Host "  [--]  $m" -ForegroundColor Gray }
function Confirm-Yes ($q){ ((Read-Host "$q [y/N]") -match '^(y|yes)$') }

function Ensure-RoleAssignment {
    param([string]$Assignee,[string]$Role,[string]$Scope,[string]$Label)
    $existing = az role assignment list --assignee $Assignee --scope $Scope `
                    --query "[?roleDefinitionName=='$Role'] | [0].id" -o tsv 2>$null
    if ($existing) { Write-Ok "$Label already has '$Role'"; return }
    az role assignment create --assignee $Assignee --role $Role --scope $Scope 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Granted '$Role' to $Label" }
    else { Write-Warn2 "Failed to grant '$Role' to $Label (may need Owner/UAA rights)" }
}

# ----------------------------- 0. context -----------------------------
Write-Step "Context"
az account set --subscription $SubscriptionId
$acct = az account show --query "{name:name, user:user.name}" -o json | ConvertFrom-Json
Write-Info "Subscription : $SubscriptionId"
Write-Info "Deployment RG: $ResourceGroup"
Write-Info "Firewall RG  : $FirewallResourceGroup"
Write-Info "Policy RG    : $PolicyResourceGroup"
Write-Info "Signed-in as : $($acct.user)"
if (-not (Test-Path $TemplateFile)) { throw "Template not found: $TemplateFile" }
Write-Info "Template     : $TemplateFile"

# ----------------------------- 1. deploy -----------------------------
Write-Step "1/6  Deploying ARM template (incremental)"
$deployName = "fwbackup-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
$out = az deployment group create `
        --name $deployName `
        --resource-group $ResourceGroup `
        --template-file $TemplateFile `
        --parameters `
            Playbook_Name=$PlaybookName `
            Storage_Account_Name=$StorageAccountName `
            Firewall_Name=$FirewallName `
            Firewall_Policy_Name=$FirewallPolicyName `
            Firewall_Resource_Group_Name=$FirewallResourceGroup `
            Policy_Resource_Group_Name=$PolicyResourceGroup `
            Subscription_Id=$SubscriptionId `
            Enable_Write_Trigger=$($EnableWriteTrigger.ToString().ToLower()) `
        -o json | ConvertFrom-Json

if ($out.properties.provisioningState -ne "Succeeded") { throw "Deployment failed: $($out.properties.provisioningState)" }
Write-Ok "Deployment '$deployName' succeeded"

$recurrencePrincipal = $out.properties.outputs.logicAppPrincipalId.value
$onWritePrincipal     = $out.properties.outputs.onWriteLogicAppPrincipalId.value
Write-Info "Recurrence Logic App identity : $recurrencePrincipal"
if ($EnableWriteTrigger) { Write-Info "OnWrite   Logic App identity : $onWritePrincipal" }

$rgScope      = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$storageScope = "$rgScope/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"

# Contributor is needed on the RG(s) that host the firewall AND the policy so the
# Logic App identities can read them for backup and (re)create/repoint them on restore.
# These may differ from the deployment RG, so grant on both (deduplicated).
$contributorRgScopes = @(
    "/subscriptions/$SubscriptionId/resourceGroups/$FirewallResourceGroup",
    "/subscriptions/$SubscriptionId/resourceGroups/$PolicyResourceGroup"
) | Select-Object -Unique

# ----------------------------- 2. Logic App roles -----------------------------
Write-Step "2/6  Assigning roles to Logic App managed identities"
foreach ($scope in $contributorRgScopes) {
    Ensure-RoleAssignment $recurrencePrincipal "Contributor" $scope "Recurrence app"
}
Ensure-RoleAssignment $recurrencePrincipal "Storage Blob Data Contributor" $storageScope "Recurrence app"
if ($EnableWriteTrigger -and $onWritePrincipal -and $onWritePrincipal -ne "N/A") {
    foreach ($scope in $contributorRgScopes) {
        Ensure-RoleAssignment $onWritePrincipal "Contributor" $scope "OnWrite app"
    }
    Ensure-RoleAssignment $onWritePrincipal "Storage Blob Data Contributor" $storageScope "OnWrite app"
}

# ----------------------------- 3. user read access -----------------------------
Write-Step "3/6  Granting the signed-in user data-plane read on the storage account"
$userObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if ($userObjectId) {
    Ensure-RoleAssignment $userObjectId "Storage Blob Data Reader" $storageScope "You ($($acct.user))"
    Write-Info "This lets you LIST/READ backup blobs (data-plane) via portal/CLI with your AAD identity."
} else {
    Write-Warn2 "Could not resolve signed-in user object id; skipping user role grant."
}

# ----------------------------- 4. network reachability -----------------------------
Write-Step "4/6  Storage network reachability"
$net = az storage account show -n $StorageAccountName -g $ResourceGroup --query networkRuleSet -o json | ConvertFrom-Json
$myIp = try { (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 10).ip } catch { $null }
Write-Info "Storage defaultAction : $($net.defaultAction)"
Write-Info "Your public IP        : $(if($myIp){$myIp}else{'unknown'})"

if ($net.defaultAction -eq "Deny") {
    Write-Host ""
    Write-Warn2 "ALERT: This storage account BLOCKS public access by default (defaultAction=Deny)."
    Write-Warn2 "       The Logic Apps write backups over the trusted Managed Identity path and WILL work,"
    Write-Warn2 "       BUT you will NOT be able to see/list the backup blobs from your machine or the"
    Write-Warn2 "       Azure portal until your IP / network is allowed on the storage firewall."
    $allowed = @($net.ipRules | ForEach-Object { $_.ipAddressOrRange })
    if ($myIp -and ($allowed -contains $myIp)) {
        Write-Ok "Your IP $myIp is already allowed."
    } else {
        Write-Warn2 "ACTION REQUIRED: This script does NOT modify the storage firewall."
        Write-Warn2 "       To view/list backups, add your IP to the storage account's network rules yourself:"
        Write-Info "  az storage account network-rule add --account-name $StorageAccountName -g $ResourceGroup --ip-address $(if($myIp){$myIp}else{'<your-ip>'})"
        Write-Info "  (or add it in the portal: Storage account > Networking > Firewalls and virtual networks)"
    }
} else {
    Write-Ok "Storage allows access (defaultAction=Allow) - you can list backups directly."
}

# ----------------------------- 5. run a baseline backup -----------------------------
Write-Step "5/6  Baseline backup"
if (Confirm-Yes "  Run a backup NOW (manually trigger the recurrence Logic App)?") {
    $trgUri = "https://management.azure.com$rgScope/providers/Microsoft.Logic/workflows/$PlaybookName/triggers/Recurrence/run?api-version=2019-05-01"
    az rest --method post --uri $trgUri 1>$null
    Write-Ok "Recurrence workflow triggered. Checking run status..."
    Start-Sleep -Seconds 45
    az rest --method get `
        --uri "https://management.azure.com$rgScope/providers/Microsoft.Logic/workflows/$PlaybookName/runs?api-version=2019-05-01" `
        --query "value[0].{status:properties.status, start:properties.startTime}" -o table
    Write-Info "Backups land in container '$BlobContainer' as backup-$FirewallName-<timestamp>.json"
} else {
    Write-Info "Skipped. It will run automatically on its recurrence schedule."
}

# ----------------------------- 6. restore as new policy + repoint -----------------------------
Write-Step "6/6  Restore latest backup as a NEW policy and repoint an existing firewall"
Write-Warn2 "This is a WRITE operation against a live firewall. Proceed carefully."
if (Confirm-Yes "  Do you want to restore a backup as a new policy and repoint a firewall?") {

    # 6a. source selection: a LOCAL file (already downloaded) OR list/download from storage
    $usedLocalFile = $false
    $localPath = Read-Host "  Path to a LOCAL backup .json (leave blank to list from storage)"
    if (-not [string]::IsNullOrWhiteSpace($localPath)) {
        $localPath = $localPath.Trim().Trim('"').Trim("'").Trim()
        if (-not (Test-Path $localPath)) { Write-Warn2 "File '$localPath' not found. Aborting restore."; return }
        # copy to a temp working file so we don't mutate/delete the user's original
        $localBackup = Join-Path $env:TEMP "restore-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item $localPath $localBackup -Force
        $usedLocalFile = $true
        Write-Ok "Using local backup file: $localPath"
    } else {

        if ($net.defaultAction -eq "Deny" -and -not ($myIp -and (az storage account network-rule list --account-name $StorageAccountName -g $ResourceGroup --query "ipRules[?ipAddressOrRange=='$myIp']" -o tsv))) {
            Write-Warn2 "Storage is IP-restricted and your IP isn't allowed - blob download will likely fail."
            if (-not (Confirm-Yes "  Continue anyway?")) { Write-Info "Restore aborted."; return }
        }

        # find the newest backup blob
        Write-Info "Listing backups in '$BlobContainer'..."
        $blobsJson = az storage blob list --account-name $StorageAccountName --container-name $BlobContainer `
                        --prefix "backup-$FirewallName-" --auth-mode login `
                        --query "sort_by([].{name:name, modified:properties.lastModified}, &name)" -o json 2>$null
        $blobs = if ($blobsJson) { $blobsJson | ConvertFrom-Json } else { @() }
        if (-not $blobs -or $blobs.Count -eq 0) { Write-Warn2 "No backups found (or no storage access). Aborting restore."; return }

        $latest = $blobs[-1].name
        Write-Info "Found $($blobs.Count) backup(s). Latest: $latest"
        $chosen = (Read-Host "  Blob to restore [default: $latest]").Trim()
        if ([string]::IsNullOrWhiteSpace($chosen)) { $chosen = $latest }

        # download it
        $localBackup = Join-Path $env:TEMP "restore-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        az storage blob download --account-name $StorageAccountName --container-name $BlobContainer `
            --name $chosen --file $localBackup --auth-mode login 1>$null
        if (-not (Test-Path $localBackup)) { Write-Warn2 "Download failed. Aborting."; return }
        Write-Ok "Downloaded $chosen"
    }

    # 6c. locate the firewallPolicies name parameter inside the backup template
    $tpl = Get-Content $localBackup -Raw | ConvertFrom-Json
    $polRes = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Network/firewallPolicies' } | Select-Object -First 1
    if (-not $polRes) { Write-Warn2 "Backup has no firewallPolicies resource. Aborting."; return }
    $polParam = $null
    if ($polRes.name -match "parameters\('([^']+)'\)") { $polParam = $Matches[1] }

    $defaultNew = "$FirewallPolicyName-restored-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
    $newPolicyName = (Read-Host "  New policy name [default: $defaultNew]").Trim()
    if ([string]::IsNullOrWhiteSpace($newPolicyName)) { $newPolicyName = $defaultNew }

    # 6d. deploy the backup as a NEW policy (override the policy-name parameter)
    Write-Info "Deploying backup as new policy '$newPolicyName'..."
    $restoreDeploy = "fwrestore-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
    if ($polParam) {
        az deployment group create --name $restoreDeploy --resource-group $PolicyResourceGroup `
            --template-file $localBackup --parameters "$polParam=$newPolicyName" -o none
    } else {
        Write-Warn2 "Could not auto-detect the policy-name parameter; deploying template as-is."
        Write-Warn2 "This may recreate the ORIGINAL policy name instead of a new one."
        if (-not (Confirm-Yes "  Continue?")) { Write-Info "Restore aborted."; return }
        az deployment group create --name $restoreDeploy --resource-group $PolicyResourceGroup `
            --template-file $localBackup -o none
    }
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "Restore deployment failed. Aborting repoint."; return }
    Write-Ok "New policy '$newPolicyName' deployed."

    # 6e. choose the target firewall to associate, then repoint it
    Write-Info "Now choose which EXISTING firewall to associate with policy '$newPolicyName'."
    $fwRg = (Read-Host "  Target firewall's resource group [default: $FirewallResourceGroup]").Trim()
    if ([string]::IsNullOrWhiteSpace($fwRg)) { $fwRg = $FirewallResourceGroup }

    # Discover firewalls in that RG to help the user pick
    $fwListJson = az network firewall list -g $fwRg --query "[].name" -o json 2>$null
    $fwList = if ($fwListJson) { $fwListJson | ConvertFrom-Json } else { @() }
    if ($fwList.Count -gt 0) {
        Write-Info "Firewalls found in '$fwRg': $($fwList -join ', ')"
    } else {
        Write-Warn2 "No firewalls discovered in '$fwRg' (list may be restricted). You can still type a name."
    }

    $targetFw = (Read-Host "  Firewall name to associate [default: $FirewallName]").Trim()
    if ([string]::IsNullOrWhiteSpace($targetFw)) { $targetFw = $FirewallName }

    # Validate the firewall exists before attempting a repoint
    $fwRgScope = "/subscriptions/$SubscriptionId/resourceGroups/$fwRg"
    $fwId      = "$fwRgScope/providers/Microsoft.Network/azureFirewalls/$targetFw"
    $exists = az resource show --ids $fwId --api-version 2023-11-01 --query "name" -o tsv 2>$null
    if (-not $exists) {
        Write-Warn2 "Firewall '$targetFw' not found in RG '$fwRg'. Repoint aborted."
        Write-Info "New policy '$newPolicyName' was created but NOT associated."
        Remove-Item $localBackup -ErrorAction SilentlyContinue
        return
    }

    # Show current association so the user knows what they're changing
    $currentPol = az resource show --ids $fwId --api-version 2023-11-01 --query "properties.firewallPolicy.id" -o tsv 2>$null
    $newPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$PolicyResourceGroup/providers/Microsoft.Network/firewallPolicies/$newPolicyName"
    Write-Warn2 "About to REPOINT firewall '$targetFw' (RG '$fwRg')."
    Write-Info  "  Current policy : $(if($currentPol){$currentPol.Split('/')[-1]}else{'<none / classic rules>'})"
    Write-Info  "  New policy     : $newPolicyName"
    Write-Warn2 "This changes the live firewall's active policy."
    if (Confirm-Yes "  Repoint '$targetFw' to '$newPolicyName' now?") {
        az resource update --ids $fwId --set "properties.firewallPolicy.id=$newPolicyId" `
            --api-version 2023-11-01 -o none
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Firewall '$targetFw' now uses policy '$newPolicyName'."
        } else {
            Write-Warn2 "Repoint failed. Firewall still on its previous policy. New policy '$newPolicyName' exists and is unused."
        }
    } else {
        Write-Info "Repoint skipped. New policy '$newPolicyName' was created but NOT associated."
    }

    Remove-Item $localBackup -ErrorAction SilentlyContinue
} else {
    Write-Info "Restore skipped."
}

Write-Step "Done"
Write-Ok "Firewall backup solution deployed and configured."
