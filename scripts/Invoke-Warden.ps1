<#
.SYNOPSIS
Syncs Entra ID with an HR export: creates joiners, updates movers, disables leavers.

.DESCRIPTION
Writes a JSON-lines audit log (one entry per action) and a drift report to
the logs folder. With -DryRun nothing in the tenant changes; the audit log
shows what would have happened.

Requires: Connect-MgGraph -Scopes 'User.ReadWrite.All','GroupMember.ReadWrite.All'

.EXAMPLE
./scripts/Invoke-Warden.ps1 -HrCsvPath ./data/hr_day1.csv -UpnDomain contoso.onmicrosoft.com -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HrCsvPath,
    [Parameter(Mandatory)][string]$UpnDomain,
    [switch]$DryRun,
    [string]$RoleMapPath = (Join-Path $PSScriptRoot '../config/roles.json'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '../logs')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Warden.psm1') -Force

if (-not (Get-MgContext)) {
    throw "Not signed in. Run: Connect-MgGraph -Scopes 'User.ReadWrite.All','GroupMember.ReadWrite.All'"
}

$hr = Import-HrRecords -Path $HrCsvPath
$map = Read-WardenRoleMap -Path $RoleMapPath

$null = New-Item -ItemType Directory -Force -Path $LogDirectory
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$mode = if ($DryRun) { 'dryrun' } else { 'apply' }
$auditPath = Join-Path $LogDirectory "audit-$stamp-$mode.jsonl"
$driftPath = Join-Path $LogDirectory "drift-$stamp.json"

$result = Invoke-WardenSync -HrRecords $hr -RoleMap $map -UpnDomain $UpnDomain -DryRun:$DryRun -AuditPath $auditPath
ConvertTo-Json -InputObject @($result.Drift) -Depth 4 | Set-Content -LiteralPath $driftPath -Encoding utf8

Write-Host ''
Write-Host ("Warden {0} run {1}" -f ($DryRun ? 'DRY-RUN' : 'APPLY'), $result.RunId)
if ($result.Actions.Count -eq 0) {
    Write-Host 'No changes needed: the tenant already matches HR.'
} else {
    $result.Counts.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-17} {1,4}' -f $_.Key, $_.Value) }
}
Write-Host ("Drift findings: {0}" -f $result.Drift.Count)
$result.Drift | Group-Object Finding -NoElement | ForEach-Object { Write-Host ('  {0,-17} {1,4}' -f $_.Name, $_.Count) }
Write-Host "Audit log:    $auditPath"
Write-Host "Drift report: $driftPath"

if ($result.Failed) {
    Write-Host "$($result.Failed) action(s) failed; see the audit log." -ForegroundColor Red
    $result.Actions | Where-Object status -eq 'Failed' | Select-Object -First 5 |
        ForEach-Object { Write-Host "  $($_.action) $($_.employeeId): $($_.error)" -ForegroundColor Red }
    exit 1
}
