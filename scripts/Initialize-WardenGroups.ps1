<#
.SYNOPSIS
Creates the security groups named in the role map, skipping any that exist.

.DESCRIPTION
Run once by an administrator before the first sync. Kept separate from the
sync so the scheduled job never needs permission to create groups, only to
manage their membership.

Requires: Connect-MgGraph -Scopes 'Group.ReadWrite.All'

.EXAMPLE
./scripts/Initialize-WardenGroups.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$RoleMapPath = (Join-Path $PSScriptRoot '../config/roles.json'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Warden.psm1') -Force

if (-not (Get-MgContext)) {
    throw "Not signed in. Run: Connect-MgGraph -Scopes 'Group.ReadWrite.All'"
}

$map = Read-WardenRoleMap -Path $RoleMapPath
$names = @(@($map.AllStaffGroup) + @($map.Departments.Values | ForEach-Object { $_ }) | Sort-Object -Unique)

foreach ($name in $names) {
    # Group names come from config, so they are quoted like any other input.
    $filter = [uri]::EscapeDataString("displayName eq $(ConvertTo-ODataLiteral $name)")
    $existing = @((Invoke-MgGraphRequest -Method GET -OutputType Hashtable `
                -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id")['value'])

    if ($existing.Count) {
        Write-Host "exists   $name"
        continue
    }
    if ($DryRun) {
        Write-Host "would create $name"
        continue
    }
    $body = @{
        displayName     = $name
        description     = 'Managed by Warden: membership is set from HR data'
        mailEnabled     = $false
        mailNickname    = $name
        securityEnabled = $true
    } | ConvertTo-Json
    $null = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body $body -ContentType 'application/json'
    Write-Host "created  $name"
}
