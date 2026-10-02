# Timer-triggered Warden sync.
#
# Signs in as the Function App's system-assigned managed identity, which holds
# only User.ReadWrite.All and GroupMember.ReadWrite.All on Microsoft Graph.
#
# App settings:
#   WARDEN_HR_CSV_B64    HR export (CSV), base64 so line breaks survive
#   WARDEN_ROLE_MAP_B64  contents of config/roles.json, base64
#   WARDEN_UPN_DOMAIN    domain for new user principal names
#   WARDEN_DRY_RUN       "true" to report changes without making them
#
# Each run writes its audit log (one JSON line per action, then a summary line)
# to the "audit" blob container, whether it succeeds or fails; a failure is
# recorded in the summary's "error" field.

param($Timer)

$ErrorActionPreference = 'Stop'

function ConvertFrom-Base64Setting([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { throw "App setting $Name is not set." }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
}

$dryRun = $env:WARDEN_DRY_RUN -eq 'true'
$lines = [System.Collections.Generic.List[string]]::new()
$summary = [ordered]@{ summary = $true; dryRun = $dryRun; startedAt = [DateTime]::UtcNow.ToString('o') }

try {
    Import-Module Warden
    Connect-MgGraph -Identity -NoWelcome

    $records = Import-HrRecords -CsvText (ConvertFrom-Base64Setting 'WARDEN_HR_CSV_B64')
    $roleMap = Read-WardenRoleMap -Json (ConvertFrom-Base64Setting 'WARDEN_ROLE_MAP_B64')
    $result = Invoke-WardenSync -HrRecords $records -RoleMap $roleMap -UpnDomain $env:WARDEN_UPN_DOMAIN -DryRun:$dryRun

    foreach ($entry in $result.Actions) { $lines.Add(($entry | ConvertTo-Json -Depth 6 -Compress)) }
    $summary.runId = $result.RunId
    $summary.counts = $result.Counts
    $summary.failed = $result.Failed
    $summary.drift = @($result.Drift)
    Write-Information ("Warden run {0}: {1} action(s), {2} failed, {3} drift finding(s)" -f
        $result.RunId, $result.Actions.Count, $result.Failed, $result.Drift.Count)
} catch {
    # Not rethrown: the Functions host discards output bindings of a failed
    # invocation, and the audit blob must record every run, failures included.
    $summary.error = $_.Exception.Message
    Write-Warning "Warden run failed: $($summary.error)"
}

$summary.finishedAt = [DateTime]::UtcNow.ToString('o')
$lines.Add(($summary | ConvertTo-Json -Depth 5 -Compress))
Push-OutputBinding -Name AuditLog -Value ($lines -join "`n")

if ($summary.Contains('failed') -and $summary.failed) {
    Write-Warning "$($summary.failed) action(s) failed; see the audit blob."
}
