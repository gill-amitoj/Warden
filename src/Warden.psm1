#Requires -Version 7.2
<#
Warden: joiner-mover-leaver provisioning for Entra ID.

The module is split so the decision logic can be tested without a tenant:

  Import-HrRecords / Read-WardenRoleMap   read and validate inputs
  Get-DesiredState                        HR records -> what each account should look like
  Get-EntraState                          what the tenant looks like now (Graph reads)
  Compare-IdentityState                   desired vs current -> ordered list of actions (pure)
  Get-AccessDrift                         desired vs current -> report of mismatches (pure)
  Invoke-IdentityAction                   performs one action (Graph writes), honours -DryRun
  Invoke-WardenSync                       runs the whole pipeline and writes the audit log

Every Graph call goes through Invoke-MgGraphRequest, so only the
Microsoft.Graph.Authentication module is required (in Azure Automation too).
#>

Set-StrictMode -Version Latest

$script:GraphBase = 'https://graph.microsoft.com/v1.0'

# Accounts carrying this companyName are owned by Warden. Everything else in
# the tenant (admins, manually created users) is read but never modified.
$script:ManagedCompany = 'Warden Labs'

# Order in which actions run: accounts must exist before they can join groups
# or be someone's manager, and managers are set last for the same reason.
$script:ActionOrder = @{
    CreateUser       = 0
    EnableUser       = 1
    UpdateAttributes = 2
    AddToGroup       = 3
    RemoveFromGroup  = 4
    DisableUser      = 5
    SetManager       = 6
    RemoveManager    = 6
    Conflict         = 9
}

$script:EmployeeIdPattern = '^E\d{3,6}$'

# Retries for writes that hit replication delay (see Invoke-WardenGraph).
$script:ReplicationRetries = 4
$script:ReplicationDelaySeconds = 3

# ============================================
# INPUT
# ============================================

function ConvertTo-ODataLiteral {
    <#
    .SYNOPSIS
    Quotes a value for use inside an OData $filter expression.
    .DESCRIPTION
    Single quotes are doubled, which is OData's escape, so a value such as
    "x' or 1 eq 1" stays a single string literal instead of extending the
    filter. Control characters are refused outright.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -match '[\x00-\x1F\x7F]') {
        throw 'Value contains control characters and cannot be used in an OData filter.'
    }
    "'" + $Value.Replace("'", "''") + "'"
}

function Import-HrRecords {
    <#
    .SYNOPSIS
    Reads the HR export and validates every row before anything acts on it.
    .DESCRIPTION
    HR data is treated as untrusted: names and departments end up in Graph
    request bodies and filters, so each field must match a strict pattern.
    All problems are collected and reported together.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][string]$CsvText
    )

    $rows = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        @(Import-Csv -LiteralPath $Path -Encoding utf8)
    } else {
        @($CsvText -split '\r?\n' | Where-Object { $_.Trim() } | ConvertFrom-Csv)
    }
    if ($rows.Count -eq 0) { throw 'HR data contains no rows.' }

    $required = 'EmployeeId', 'FirstName', 'LastName', 'Department', 'JobTitle', 'ManagerId', 'Status'
    $columns = $rows[0].PSObject.Properties.Name
    $missing = @($required | Where-Object { $_ -notin $columns })
    if ($missing) { throw "HR data is missing column(s): $($missing -join ', ')" }

    $errors = [System.Collections.Generic.List[string]]::new()
    $ids = @{}
    $records = foreach ($row in $rows) {
        $r = [pscustomobject]@{
            EmployeeId = "$($row.EmployeeId)".Trim()
            FirstName  = "$($row.FirstName)".Trim()
            LastName   = "$($row.LastName)".Trim()
            Department = "$($row.Department)".Trim()
            JobTitle   = "$($row.JobTitle)".Trim()
            ManagerId  = "$($row.ManagerId)".Trim()
            Status     = "$($row.Status)".Trim()
        }
        $label = if ($r.EmployeeId) { $r.EmployeeId } else { '(blank id)' }

        if ($r.EmployeeId -notmatch $script:EmployeeIdPattern) { $errors.Add("${label}: EmployeeId must look like E001") }
        elseif ($ids.ContainsKey($r.EmployeeId)) { $errors.Add("${label}: duplicate EmployeeId") }
        else { $ids[$r.EmployeeId] = $true }

        foreach ($field in 'FirstName', 'LastName') {
            if ($r.$field -notmatch "^\p{L}[\p{L} '\-]{0,63}$") { $errors.Add("${label}: $field has unsupported characters") }
        }
        if ($r.Department -notmatch '^\p{L}[\p{L} &\-]{0,63}$') { $errors.Add("${label}: Department has unsupported characters") }
        if ($r.JobTitle -notmatch '^[\p{L}\d][\p{L}\d ,&/\-]{0,127}$') { $errors.Add("${label}: JobTitle has unsupported characters") }
        if ($r.Status -cnotin 'Active', 'Terminated') { $errors.Add("${label}: Status must be Active or Terminated") }
        $r
    }

    foreach ($r in $records) {
        if (-not $r.ManagerId) { continue }
        if ($r.ManagerId -eq $r.EmployeeId) { $errors.Add("$($r.EmployeeId): cannot be their own manager") }
        elseif (-not $ids.ContainsKey($r.ManagerId)) { $errors.Add("$($r.EmployeeId): manager $($r.ManagerId) is not in the HR data") }
    }

    if ($errors.Count) { throw "HR data failed validation:`n - " + ($errors -join "`n - ") }
    $records
}

function Read-WardenRoleMap {
    <#
    .SYNOPSIS
    Loads the department-to-groups map and checks every group carries the prefix.
    .DESCRIPTION
    Warden only ever removes memberships of groups with the prefix, so a group
    outside it in the map would be granted but never revoked.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string]$Json
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') { $Json = Get-Content -LiteralPath $Path -Raw }
    $raw = $Json | ConvertFrom-Json -AsHashtable
    $prefix = [string]$raw['groupPrefix']
    if (-not $prefix) { throw 'Role map needs a groupPrefix.' }

    $map = @{
        GroupPrefix   = $prefix
        AllStaffGroup = [string]$raw['allStaffGroup']
        Departments   = @{}
    }
    foreach ($dept in $raw['departments'].Keys) {
        $map.Departments[$dept] = @($raw['departments'][$dept])
    }

    $allGroups = @($map.AllStaffGroup) + @($map.Departments.Values | ForEach-Object { $_ })
    $bad = @($allGroups | Where-Object { -not $_ -or -not $_.StartsWith($prefix) })
    if ($bad) { throw "Role map groups must start with '$prefix': $($bad -join ', ')" }
    $map
}

# ============================================
# DESIRED STATE
# ============================================

function Get-MailNickname {
    # "José Álvarez" -> "jose.alvarez", "Siobhan O'Brien" -> "siobhan.obrien"
    param([string]$FirstName, [string]$LastName)

    $decomposed = "$FirstName.$LastName".Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    (($sb.ToString().ToLowerInvariant() -replace '[^a-z.]', '') -replace '\.{2,}', '.').Trim('.')
}

function Get-DesiredState {
    <#
    .SYNOPSIS
    Turns validated HR records into the account each employee should have.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][hashtable]$RoleMap,
        [Parameter(Mandatory)][string]$UpnDomain
    )

    if ($UpnDomain -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw "UpnDomain '$UpnDomain' is not a valid domain name." }

    $unknown = @($Records | Where-Object { -not $RoleMap.Departments.ContainsKey($_.Department) } |
        ForEach-Object { "$($_.EmployeeId) ($($_.Department))" })
    if ($unknown) { throw "Department not in role map: $($unknown -join ', ')" }

    # Two people with the same name get their employee id appended, so the
    # UPN is unique and stays the same however the HR file is ordered.
    $aliases = @{}
    foreach ($r in $Records) {
        $alias = Get-MailNickname $r.FirstName $r.LastName
        $aliases[$r.EmployeeId] = if ($alias) { $alias } else { $r.EmployeeId.ToLowerInvariant() }
    }
    $taken = $aliases.Values | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
    foreach ($id in @($aliases.Keys)) {
        if ($aliases[$id] -in $taken) { $aliases[$id] = "$($aliases[$id]).$($id.ToLowerInvariant())" }
    }

    foreach ($r in $Records) {
        $active = $r.Status -eq 'Active'
        $groups = @(if ($active) { @($RoleMap.AllStaffGroup) + $RoleMap.Departments[$r.Department] | Sort-Object -Unique })

        [pscustomobject]@{
            EmployeeId        = $r.EmployeeId
            UserPrincipalName = "$($aliases[$r.EmployeeId])@$UpnDomain"
            MailNickname      = $aliases[$r.EmployeeId]
            DisplayName       = "$($r.FirstName) $($r.LastName)"
            GivenName         = $r.FirstName
            Surname           = $r.LastName
            Department        = $r.Department
            JobTitle          = $r.JobTitle
            ManagerId         = if ($r.ManagerId) { $r.ManagerId } else { $null }
            Active            = $active
            Groups            = $groups
        }
    }
}

# ============================================
# CURRENT STATE (Graph reads)
# ============================================

function Invoke-WardenGraph {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )
    $request = @{ Method = $Method; Uri = "$script:GraphBase$Uri"; OutputType = 'Hashtable' }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 5 -Compress
        $request.ContentType = 'application/json'
    }

    # A user or group created moments ago can briefly return 404 while the
    # directory replicates, so not-found is retried with backoff.
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-MgGraphRequest @request
        } catch {
            $notFound = $_.Exception.Message -match '404|NotFound|ResourceNotFound|does not exist'
            if (-not $notFound -or $attempt -ge $script:ReplicationRetries) { throw }
            Start-Sleep -Seconds ($script:ReplicationDelaySeconds * $attempt)
        }
    }
}

function Get-WardenGraphCollection {
    # Follows @odata.nextLink so large tenants are read completely.
    param([Parameter(Mandatory)][string]$Uri)

    $next = "$script:GraphBase$Uri"
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable
        foreach ($item in @($page['value'])) { $item }
        $next = $page['@odata.nextLink']
    }
}

function Get-EntraState {
    <#
    .SYNOPSIS
    Reads users, the prefixed groups and their members from the tenant.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GroupPrefix)

    $select = 'id,userPrincipalName,displayName,givenName,surname,department,jobTitle,employeeId,companyName,accountEnabled'
    $rawUsers = @(Get-WardenGraphCollection "/users?`$select=$select&`$expand=manager(`$select=id)&`$top=100")

    $filter = [uri]::EscapeDataString("startswith(displayName,$(ConvertTo-ODataLiteral $GroupPrefix))")
    $rawGroups = @(Get-WardenGraphCollection "/groups?`$filter=$filter&`$select=id,displayName&`$top=999")

    $groupIds = @{}
    $members = @{}
    $groupsByUser = @{}
    foreach ($g in $rawGroups) {
        $name = $g['displayName']
        $groupIds[$name] = $g['id']
        $members[$name] = @(Get-WardenGraphCollection "/groups/$($g['id'])/members?`$select=id&`$top=999" |
            ForEach-Object { $_['id'] })
        foreach ($id in $members[$name]) {
            if (-not $groupsByUser.ContainsKey($id)) { $groupsByUser[$id] = [System.Collections.Generic.List[string]]::new() }
            $groupsByUser[$id].Add($name)
        }
    }

    $employeeIdByObjectId = @{}
    foreach ($u in $rawUsers) {
        if ($u['companyName'] -ceq $script:ManagedCompany -and $u['employeeId']) { $employeeIdByObjectId[$u['id']] = $u['employeeId'] }
    }

    $users = foreach ($u in $rawUsers) {
        $managerId = $null
        if ($u['manager']) {
            $mid = $u['manager']['id']
            # A manager Warden does not own is recorded as such, so it never
            # matches an HR manager id and gets corrected.
            $managerId = if ($employeeIdByObjectId.ContainsKey($mid)) { $employeeIdByObjectId[$mid] } else { "unmanaged:$mid" }
        }
        [pscustomobject]@{
            Id                = $u['id']
            EmployeeId        = $u['employeeId']
            UserPrincipalName = $u['userPrincipalName']
            DisplayName       = $u['displayName']
            GivenName         = $u['givenName']
            Surname           = $u['surname']
            Department        = $u['department']
            JobTitle          = $u['jobTitle']
            AccountEnabled    = [bool]$u['accountEnabled']
            ManagerId         = $managerId
            Groups            = @($groupsByUser[$u['id']] | Sort-Object)
            Managed           = $employeeIdByObjectId.ContainsKey($u['id'])
        }
    }

    [pscustomobject]@{
        Users        = @($users)
        Groups       = $groupIds
        GroupMembers = $members
    }
}

# ============================================
# DECISIONS (pure)
# ============================================

function New-WardenAction {
    param([string]$Type, $Desired, [string]$Group, [hashtable]$Details = @{})
    [pscustomobject]@{
        Type              = $Type
        EmployeeId        = $Desired.EmployeeId
        UserPrincipalName = $Desired.UserPrincipalName
        Group             = $Group
        Details           = $Details
    }
}

function Compare-IdentityState {
    <#
    .SYNOPSIS
    Works out what to change so the tenant matches HR. Makes no calls.
    .DESCRIPTION
    Each user's current state is checked before an action is proposed, so a
    second run against an up-to-date tenant returns nothing: that is what
    makes the sync idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Desired,
        [Parameter(Mandatory)]$Current
    )

    $byEmployee = @{}
    $byUpn = @{}
    foreach ($u in $Current.Users) {
        if ($u.Managed) { $byEmployee[$u.EmployeeId] = $u }
        if ($u.UserPrincipalName) { $byUpn[$u.UserPrincipalName.ToLowerInvariant()] = $u }
    }

    $actions = foreach ($d in ($Desired | Sort-Object EmployeeId)) {
        $c = $byEmployee[$d.EmployeeId]

        if (-not $c) {
            # Never provisioned; nothing to do for someone who already left.
            if (-not $d.Active) { continue }
            if ($byUpn.ContainsKey($d.UserPrincipalName.ToLowerInvariant())) {
                New-WardenAction Conflict $d -Details @{ Reason = 'UPN is already used by an account Warden does not manage' }
                continue
            }
            New-WardenAction CreateUser $d
            foreach ($g in $d.Groups) { New-WardenAction AddToGroup $d -Group $g }
            if ($d.ManagerId) { New-WardenAction SetManager $d -Details @{ ManagerId = $d.ManagerId } }
            continue
        }

        if ($d.Active) {
            $changes = [ordered]@{}
            $previous = [ordered]@{}
            foreach ($p in 'DisplayName', 'GivenName', 'Surname', 'Department', 'JobTitle') {
                if ($d.$p -cne $c.$p) {
                    $key = $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(1)
                    $changes[$key] = $d.$p
                    $previous[$key] = $c.$p
                }
            }
            if ($changes.Count) { New-WardenAction UpdateAttributes $d -Details @{ Changes = $changes; Previous = $previous } }
            if (-not $c.AccountEnabled) { New-WardenAction EnableUser $d }

            foreach ($g in $d.Groups) { if ($g -notin $c.Groups) { New-WardenAction AddToGroup $d -Group $g } }
            foreach ($g in $c.Groups) { if ($g -notin $d.Groups) { New-WardenAction RemoveFromGroup $d -Group $g } }

            if ($d.ManagerId -ne $c.ManagerId) {
                if ($d.ManagerId) { New-WardenAction SetManager $d -Details @{ ManagerId = $d.ManagerId } }
                else { New-WardenAction RemoveManager $d }
            }
        } else {
            # Leaver: disabled and stripped of access, but kept for audit.
            if ($c.AccountEnabled) { New-WardenAction DisableUser $d }
            foreach ($g in $c.Groups) { New-WardenAction RemoveFromGroup $d -Group $g }
        }
    }

    @($actions) | Sort-Object -Stable -Property @{ Expression = { $script:ActionOrder[$_.Type] } }
}

function Get-AccessDrift {
    <#
    .SYNOPSIS
    Reports where the tenant disagrees with HR, including things sync won't touch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Desired,
        [Parameter(Mandatory)]$Current
    )

    $desiredById = @{}
    foreach ($d in $Desired) { $desiredById[$d.EmployeeId] = $d }
    $userById = @{}
    foreach ($u in $Current.Users) { $userById[$u.Id] = $u }

    $finding = {
        param($Type, $User, $Group, $Detail)
        [pscustomobject]@{
            Finding           = $Type
            EmployeeId        = $User.EmployeeId
            UserPrincipalName = $User.UserPrincipalName
            Group             = $Group
            Detail            = $Detail
        }
    }

    foreach ($group in ($Current.GroupMembers.Keys | Sort-Object)) {
        foreach ($id in $Current.GroupMembers[$group]) {
            $u = $userById[$id]
            if ($u -and -not $u.Managed) {
                & $finding UnmanagedMember $u $group 'Member of a Warden group but not provisioned from HR'
            }
        }
    }

    foreach ($u in ($Current.Users | Where-Object Managed | Sort-Object EmployeeId)) {
        $d = $desiredById[$u.EmployeeId]
        if (-not $d) { & $finding OrphanAccount $u $null 'Managed account with no HR record'; continue }
        if (-not $d.Active) {
            if ($u.AccountEnabled) { & $finding EnabledLeaver $u $null 'Terminated in HR but the account is enabled' }
            foreach ($g in $u.Groups) { & $finding ExcessAccess $u $g 'Terminated in HR but still has access' }
            continue
        }
        foreach ($g in $d.Groups) { if ($g -notin $u.Groups) { & $finding MissingAccess $u $g 'Role grants this group' } }
        foreach ($g in $u.Groups) { if ($g -notin $d.Groups) { & $finding ExcessAccess $u $g 'Role does not grant this group' } }
    }
}

# ============================================
# ACTIONS (Graph writes)
# ============================================

function New-WardenPassword {
    # Initial password for a synthetic account; never logged or returned.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+'
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt 24) { $chars.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    -join ($chars | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

function Invoke-IdentityAction {
    <#
    .SYNOPSIS
    Performs one action against Graph. Never throws: failures are returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$DryRun
    )

    if ($Action.Type -eq 'Conflict') { return [pscustomobject]@{ Status = 'Skipped'; Error = $Action.Details.Reason } }
    if ($DryRun) { return [pscustomobject]@{ Status = 'DryRun'; Error = $null } }

    try {
        $userId = $Context.UserIds[$Action.EmployeeId]
        if ($Action.Type -ne 'CreateUser' -and -not $userId) {
            throw "No account exists for $($Action.EmployeeId)"
        }
        $groupId = $null
        if ($Action.Group) {
            $groupId = $Context.GroupIds[$Action.Group]
            if (-not $groupId) { throw "Group '$($Action.Group)' does not exist; run Initialize-WardenGroups.ps1" }
        }

        switch ($Action.Type) {
            'CreateUser' {
                $d = $Context.Desired[$Action.EmployeeId]
                $created = Invoke-WardenGraph POST '/users' @{
                    accountEnabled    = $true
                    displayName       = $d.DisplayName
                    givenName         = $d.GivenName
                    surname           = $d.Surname
                    mailNickname      = $d.MailNickname
                    userPrincipalName = $d.UserPrincipalName
                    department        = $d.Department
                    jobTitle          = $d.JobTitle
                    employeeId        = $d.EmployeeId
                    companyName       = $script:ManagedCompany
                    passwordProfile   = @{ forceChangePasswordNextSignIn = $true; password = New-WardenPassword }
                }
                $Context.UserIds[$Action.EmployeeId] = $created['id']
            }
            'UpdateAttributes' { $null = Invoke-WardenGraph PATCH "/users/$userId" $Action.Details.Changes }
            'EnableUser' { $null = Invoke-WardenGraph PATCH "/users/$userId" @{ accountEnabled = $true } }
            'DisableUser' {
                $null = Invoke-WardenGraph PATCH "/users/$userId" @{ accountEnabled = $false }
                # Disabling blocks new sign-ins; revoking ends existing sessions.
                $null = Invoke-WardenGraph POST "/users/$userId/revokeSignInSessions"
            }
            'AddToGroup' {
                $null = Invoke-WardenGraph POST "/groups/$groupId/members/`$ref" @{ '@odata.id' = "$script:GraphBase/directoryObjects/$userId" }
            }
            'RemoveFromGroup' { $null = Invoke-WardenGraph DELETE "/groups/$groupId/members/$userId/`$ref" }
            'SetManager' {
                $managerId = $Context.UserIds[$Action.Details.ManagerId]
                if (-not $managerId) { throw "Manager $($Action.Details.ManagerId) has no account" }
                $null = Invoke-WardenGraph PUT "/users/$userId/manager/`$ref" @{ '@odata.id' = "$script:GraphBase/users/$managerId" }
            }
            'RemoveManager' { $null = Invoke-WardenGraph DELETE "/users/$userId/manager/`$ref" }
            default { throw "Unknown action type '$($Action.Type)'" }
        }
        [pscustomobject]@{ Status = 'Applied'; Error = $null }
    } catch {
        [pscustomobject]@{ Status = 'Failed'; Error = $_.Exception.Message }
    }
}

# ============================================
# PIPELINE
# ============================================

function Invoke-WardenSync {
    <#
    .SYNOPSIS
    Reads HR and the tenant, reports drift, applies changes and audits each one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$HrRecords,
        [Parameter(Mandatory)][hashtable]$RoleMap,
        [Parameter(Mandatory)][string]$UpnDomain,
        [switch]$DryRun,
        [string]$AuditPath
    )

    $runId = [guid]::NewGuid().ToString()
    $desired = @(Get-DesiredState -Records $HrRecords -RoleMap $RoleMap -UpnDomain $UpnDomain)
    $current = Get-EntraState -GroupPrefix $RoleMap.GroupPrefix
    $drift = @(Get-AccessDrift -Desired $desired -Current $current)
    $actions = @(Compare-IdentityState -Desired $desired -Current $current)

    $context = @{ UserIds = @{}; GroupIds = $current.Groups; Desired = @{} }
    foreach ($u in $current.Users) { if ($u.Managed) { $context.UserIds[$u.EmployeeId] = $u.Id } }
    foreach ($d in $desired) { $context.Desired[$d.EmployeeId] = $d }

    $entries = foreach ($a in $actions) {
        $result = Invoke-IdentityAction -Action $a -Context $context -DryRun:$DryRun
        $entry = [ordered]@{
            timestamp         = [DateTime]::UtcNow.ToString('o')
            runId             = $runId
            dryRun            = [bool]$DryRun
            action            = $a.Type
            employeeId        = $a.EmployeeId
            userPrincipalName = $a.UserPrincipalName
            group             = $a.Group
            details           = $a.Details
            status            = $result.Status
            error             = $result.Error
        }
        if ($AuditPath) { $entry | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $AuditPath -Encoding utf8 }
        [pscustomobject]$entry
    }
    $entries = @($entries)

    [pscustomobject]@{
        RunId   = $runId
        DryRun  = [bool]$DryRun
        Actions = $entries
        Drift   = $drift
        Counts  = $entries | Group-Object action -NoElement | Sort-Object Name |
            ForEach-Object -Begin { $h = [ordered]@{} } -Process { $h[$_.Name] = $_.Count } -End { $h }
        Failed  = @($entries | Where-Object status -eq 'Failed').Count
    }
}

Export-ModuleMember -Function ConvertTo-ODataLiteral, Import-HrRecords, Read-WardenRoleMap, Get-DesiredState,
    Get-EntraState, Compare-IdentityState, Get-AccessDrift, Invoke-IdentityAction, Invoke-WardenSync
