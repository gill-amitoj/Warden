<#
.SYNOPSIS
Deploys Warden as a daily timer-triggered Azure Function.

.DESCRIPTION
1. Packages the function with the Warden module and Microsoft.Graph.Authentication.
2. Deploys infra/main.bicep (storage, Consumption plan, Function App with a
   system-assigned managed identity).
3. Grants that identity exactly two Graph application permissions:
   User.ReadWrite.All and GroupMember.ReadWrite.All.
4. Uploads the package.
5. With -RunNow, triggers the function once and prints the audit summary.

Safe to re-run. Uses the Azure CLI login (az login) of an account allowed to
grant Graph application permissions.

.EXAMPLE
./infra/Deploy-Warden.ps1 -UpnDomain contoso.onmicrosoft.com -HrCsvPath ./data/hr_day2.csv -RunNow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UpnDomain,
    [Parameter(Mandatory)][string]$HrCsvPath,
    [string]$ResourceGroup = 'warden-rg',
    [string]$Location = 'canadacentral',
    # Live mode makes changes; the default only reports them.
    [switch]$Live,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphRoles = 'User.ReadWrite.All', 'GroupMember.ReadWrite.All'

function Invoke-AzJson {
    # Runs an az command and returns its JSON output parsed; throws on failure.
    $out = & az @args --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed: $out" }
    $json = ($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($json.Trim()) { $json | ConvertFrom-Json -Depth 20 }
}

function Invoke-Graph([string]$Method, [string]$Url, $Body) {
    $azArgs = @('rest', '--method', $Method, '--url', $Url)
    if ($null -ne $Body) {
        $tmp = New-TemporaryFile
        $Body | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
        $azArgs += @('--body', "@$tmp", '--headers', 'Content-Type=application/json')
    }
    try { Invoke-AzJson @azArgs } finally { if ($null -ne $Body) { Remove-Item $tmp -Force } }
}

# --------------------------------------------
Write-Host '1/5 Packaging'
$hr = Import-Csv -LiteralPath $HrCsvPath   # fail early on an unreadable file
$stage = Join-Path ([IO.Path]::GetTempPath()) "warden-pkg-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $stage
Copy-Item -Recurse -Path (Join-Path $root 'function/*') -Destination $stage
$null = New-Item -ItemType Directory -Path (Join-Path $stage 'Modules/Warden')
Copy-Item (Join-Path $root 'src/Warden.psm1') (Join-Path $stage 'Modules/Warden/')
$graphModule = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
if (-not $graphModule) { throw 'Install-Module Microsoft.Graph.Authentication first; it is bundled into the package.' }
$graphDest = Join-Path $stage "Modules/Microsoft.Graph.Authentication/$($graphModule.Version)"
$null = New-Item -ItemType Directory -Force -Path $graphDest
Copy-Item -Recurse -Path (Join-Path $graphModule.ModuleBase '*') -Destination $graphDest
$zip = Join-Path ([IO.Path]::GetTempPath()) 'warden-function.zip'
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -Recurse -Force $stage
Write-Host ("    {0:N1} MB, Graph module {1}, HR rows {2}" -f ((Get-Item $zip).Length / 1MB), $graphModule.Version, @($hr).Count)

# --------------------------------------------
Write-Host '2/5 Deploying infrastructure'
$null = Invoke-AzJson group create --name $ResourceGroup --location $Location
$toB64 = { param($Path) [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $Path))) }
$paramFile = New-TemporaryFile
@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        hrCsvBase64   = @{ value = & $toB64 $HrCsvPath }
        roleMapBase64 = @{ value = & $toB64 (Join-Path $root 'config/roles.json') }
        upnDomain     = @{ value = $UpnDomain }
        dryRun        = @{ value = -not $Live }
    }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $paramFile -Encoding utf8
try {
    $outputs = (Invoke-AzJson deployment group create --resource-group $ResourceGroup `
            --template-file (Join-Path $root 'infra/main.bicep') --parameters "@$paramFile").properties.outputs
} finally { Remove-Item $paramFile -Force }
$appName = $outputs.appName.value
$principalId = $outputs.principalId.value
Write-Host "    $appName ($(if ($Live) { 'LIVE' } else { 'dry-run' }) mode)"

# --------------------------------------------
Write-Host '3/5 Granting Graph permissions to the managed identity'
$filter = [uri]::EscapeDataString("appId eq '$graphAppId'")
$graphSp = (Invoke-Graph GET "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appRoles").value[0]
$existing = @((Invoke-Graph GET "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments").value)
foreach ($roleName in $graphRoles) {
    $role = $graphSp.appRoles | Where-Object { $_.value -eq $roleName -and $_.allowedMemberTypes -contains 'Application' }
    if ($existing | Where-Object appRoleId -eq $role.id) { Write-Host "    $roleName (already granted)"; continue }
    $null = Invoke-Graph POST "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" @{
        principalId = $principalId; resourceId = $graphSp.id; appRoleId = $role.id
    }
    Write-Host "    $roleName"
}

# --------------------------------------------
Write-Host '4/5 Uploading function code'
$null = Invoke-AzJson functionapp deployment source config-zip --resource-group $ResourceGroup --name $appName --src $zip
Remove-Item $zip -Force
$functions = @(Invoke-AzJson functionapp function list --resource-group $ResourceGroup --name $appName)
Write-Host "    functions: $(($functions.name | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')"

# --------------------------------------------
if (-not $RunNow) { Write-Host '5/5 Skipped test run (use -RunNow)'; return }

Write-Host '5/5 Triggering a run'
$storage = $outputs.storageName.value
$key = az storage account keys list -g $ResourceGroup -n $storage --query '[0].value' -o tsv --only-show-errors
$before = @(Invoke-AzJson storage blob list --account-name $storage --account-key $key -c audit --query '[].name')

# Timer functions are started through the host's admin endpoint with the master key.
$masterKey = az functionapp keys list -g $ResourceGroup -n $appName --query masterKey -o tsv --only-show-errors
$response = Invoke-WebRequest -Method POST -Uri "https://$appName.azurewebsites.net/admin/functions/WardenSync" `
    -Headers @{ 'x-functions-key' = $masterKey } -ContentType 'application/json' -Body '{"input":""}' -SkipHttpErrorCheck
if ($response.StatusCode -ne 202) { throw "Trigger failed: HTTP $($response.StatusCode)" }

$blob = $null
for ($i = 0; $i -lt 60 -and -not $blob; $i++) {
    Start-Sleep -Seconds 10
    $blob = @(Invoke-AzJson storage blob list --account-name $storage --account-key $key -c audit --query '[].name') |
        Where-Object { $_ -notin $before } | Select-Object -First 1
    if (-not $blob) { Write-Host '    waiting for audit log...' }
}
if (-not $blob) { throw 'No audit log appeared within 10 minutes.' }

$local = New-TemporaryFile
$null = az storage blob download --account-name $storage --account-key $key -c audit -n $blob -f $local --only-show-errors --no-progress
$lines = @(Get-Content -LiteralPath $local | ForEach-Object { $_ | ConvertFrom-Json })
Remove-Item $local -Force
$summary = $lines[-1]
Write-Host "    audit blob: audit/$blob"
if ($summary.PSObject.Properties.Name -contains 'error') {
    Write-Host "    FAILED: $($summary.error)" -ForegroundColor Red
    exit 1
}
Write-Host ("    run {0}: {1} action(s), {2} failed, {3} drift finding(s), dry-run={4}" -f
    $summary.runId, ($lines.Count - 1), $summary.failed, @($summary.drift).Count, $summary.dryRun)
$summary.counts.PSObject.Properties | ForEach-Object { Write-Host ('      {0,-17} {1,4}' -f $_.Name, $_.Value) }
