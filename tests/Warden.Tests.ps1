BeforeAll {
    Import-Module "$PSScriptRoot/../src/Warden.psm1" -Force

    $script:Root = Resolve-Path "$PSScriptRoot/.."
    $script:Domain = 'contoso.onmicrosoft.com'
    $script:RoleMap = Read-WardenRoleMap -Path "$Root/config/roles.json"

    function Get-Desired([string]$File) {
        $hr = Import-HrRecords -Path "$Root/data/$File"
        @(Get-DesiredState -Records $hr -RoleMap $RoleMap -UpnDomain $Domain)
    }

    # Builds the tenant state that a fully applied sync of $Desired would leave.
    function New-TenantFromDesired([object[]]$Desired) {
        $members = @{}
        $users = foreach ($d in $Desired) {
            foreach ($g in $d.Groups) {
                if (-not $members.ContainsKey($g)) { $members[$g] = [System.Collections.Generic.List[string]]::new() }
                $members[$g].Add("id-$($d.EmployeeId)")
            }
            [pscustomobject]@{
                Id = "id-$($d.EmployeeId)"; EmployeeId = $d.EmployeeId; UserPrincipalName = $d.UserPrincipalName
                DisplayName = $d.DisplayName; GivenName = $d.GivenName; Surname = $d.Surname
                Department = $d.Department; JobTitle = $d.JobTitle; AccountEnabled = $d.Active
                ManagerId = $d.ManagerId; Groups = @($d.Groups); Managed = $true
            }
        }
        $groups = @{}
        foreach ($g in $members.Keys) { $groups[$g] = "gid-$g" }
        [pscustomobject]@{ Users = @($users); Groups = $groups; GroupMembers = $members }
    }

    function New-HrCsv([string[]]$Rows) {
        (@('EmployeeId,FirstName,LastName,Department,JobTitle,ManagerId,Status') + $Rows) -join "`n"
    }
}

Describe 'ConvertTo-ODataLiteral' {
    It 'quotes a plain value' {
        ConvertTo-ODataLiteral 'Engineering' | Should -Be "'Engineering'"
    }

    It 'doubles apostrophes so names like O''Brien stay one literal' {
        ConvertTo-ODataLiteral "O'Brien" | Should -Be "'O''Brien'"
    }

    It 'keeps an injection attempt inside the literal' {
        $literal = ConvertTo-ODataLiteral "x' or startswith(displayName,'a"
        $literal | Should -Be "'x'' or startswith(displayName,''a'"
        # Every quote inside is doubled, so the literal cannot be closed early.
        ($literal.Substring(1, $literal.Length - 2) -replace "''", '') | Should -Not -Match "'"
    }

    It 'refuses control characters' {
        { ConvertTo-ODataLiteral "a`nb" } | Should -Throw '*control characters*'
    }
}

Describe 'Import-HrRecords' {
    It 'loads the 50-employee day 1 file' {
        @(Import-HrRecords -Path "$Root/data/hr_day1.csv").Count | Should -Be 50
    }

    It 'reads CSV text, as the Automation runbook does' {
        $csv = New-HrCsv 'E001,Ada,Lovelace,Engineering,Engineer,,Active'
        @(Import-HrRecords -CsvText $csv)[0].FirstName | Should -Be 'Ada'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a duplicate id'; Rows = @('E001,Ada,Lovelace,Engineering,Engineer,,Active', 'E001,Bo,Lee,Sales,Rep,,Active'); Message = '*duplicate EmployeeId*' }
        @{ Case = 'an unknown status'; Rows = @('E001,Ada,Lovelace,Engineering,Engineer,,Retired'); Message = '*Status must be*' }
        @{ Case = 'a missing manager'; Rows = @('E001,Ada,Lovelace,Engineering,Engineer,E999,Active'); Message = '*manager E999 is not in the HR data*' }
        @{ Case = 'a self-managed employee'; Rows = @('E001,Ada,Lovelace,Engineering,Engineer,E001,Active'); Message = '*own manager*' }
        @{ Case = 'markup in a name'; Rows = @('E001,<script>,Lovelace,Engineering,Engineer,,Active'); Message = '*FirstName has unsupported characters*' }
        @{ Case = 'filter syntax in a department'; Rows = @("E001,Ada,Lovelace,Eng' or 1 eq 1,Engineer,,Active"); Message = '*Department has unsupported characters*' }
        @{ Case = 'a malformed id'; Rows = @('1,Ada,Lovelace,Engineering,Engineer,,Active'); Message = '*must look like E001*' }
    ) {
        { Import-HrRecords -CsvText (New-HrCsv $Rows) } | Should -Throw $Message
    }

    It 'reports every problem at once' {
        $csv = New-HrCsv 'E001,<x>,Lovelace,Engineering,Engineer,,Retired'
        $err = { Import-HrRecords -CsvText $csv } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'FirstName'
        $err.Exception.Message | Should -Match 'Status'
    }

    It 'rejects a file with a missing column' {
        { Import-HrRecords -CsvText "EmployeeId,FirstName`nE001,Ada" } | Should -Throw '*missing column*'
    }
}

Describe 'Get-DesiredState' {
    BeforeAll { $script:Day1 = Get-Desired 'hr_day1.csv' }

    It 'builds a UPN from <Who>' -ForEach @(
        @{ Who = 'an apostrophe'; Id = 'E008'; Upn = 'siobhan.obrien@contoso.onmicrosoft.com' }
        @{ Who = 'accents'; Id = 'E011'; Upn = 'jose.alvarez@contoso.onmicrosoft.com' }
        @{ Who = 'a hyphen'; Id = 'E012'; Upn = 'marykate.lin@contoso.onmicrosoft.com' }
    ) {
        ($Day1 | Where-Object EmployeeId -eq $Id).UserPrincipalName | Should -Be $Upn
    }

    It 'gives two people with the same name distinct UPNs' {
        $kims = $Day1 | Where-Object { $_.DisplayName -eq 'Alex Kim' }
        $kims.UserPrincipalName | Should -Be @('alex.kim.e009@contoso.onmicrosoft.com', 'alex.kim.e010@contoso.onmicrosoft.com')
    }

    It 'grants all-staff plus the department groups' {
        ($Day1 | Where-Object EmployeeId -eq 'E020').Groups | Should -Be @('warden-all-staff', 'warden-crm', 'warden-sales')
    }

    It 'grants nothing to leavers' {
        $hr = Import-HrRecords -CsvText (New-HrCsv 'E001,Ada,Lovelace,Engineering,Engineer,,Terminated')
        $d = @(Get-DesiredState -Records $hr -RoleMap $RoleMap -UpnDomain $Domain)
        $d[0].Groups.Count | Should -Be 0
        $d[0].Active | Should -BeFalse
    }

    It 'rejects a department the role map does not know' {
        $hr = Import-HrRecords -CsvText (New-HrCsv 'E001,Ada,Lovelace,Legal,Counsel,,Active')
        { Get-DesiredState -Records $hr -RoleMap $RoleMap -UpnDomain $Domain } | Should -Throw '*Legal*'
    }

    It 'rejects an invalid UPN domain' {
        $hr = Import-HrRecords -CsvText (New-HrCsv 'E001,Ada,Lovelace,Engineering,Engineer,,Active')
        { Get-DesiredState -Records $hr -RoleMap $RoleMap -UpnDomain "evil.com'/x" } | Should -Throw '*not a valid domain*'
    }
}

Describe 'Read-WardenRoleMap' {
    It 'reads JSON text, as the Automation runbook does' {
        $map = Read-WardenRoleMap -Json (Get-Content "$Root/config/roles.json" -Raw)
        $map.Departments['Sales'] | Should -Be @('warden-sales', 'warden-crm')
    }

    It 'refuses groups without the prefix, which could never be revoked' {
        $path = Join-Path $TestDrive 'roles.json'
        '{"groupPrefix":"warden-","allStaffGroup":"warden-all","departments":{"Sales":["Domain Admins"]}}' | Set-Content $path
        { Read-WardenRoleMap -Path $path } | Should -Throw '*Domain Admins*'
    }
}

Describe 'Compare-IdentityState' {
    BeforeAll {
        $script:Day1 = Get-Desired 'hr_day1.csv'
        $script:Day2 = Get-Desired 'hr_day2.csv'
        $script:Empty = [pscustomobject]@{ Users = @(); Groups = @{}; GroupMembers = @{} }
    }

    It 'provisions everyone on an empty tenant' {
        $actions = @(Compare-IdentityState -Desired $Day1 -Current $Empty)
        @($actions | Where-Object Type -eq CreateUser).Count | Should -Be 50
        @($actions | Where-Object Type -eq SetManager).Count | Should -Be 49
    }

    It 'orders creates before group adds before managers' {
        [string[]]$types = @(Compare-IdentityState -Desired $Day1 -Current $Empty).Type
        [array]::IndexOf($types, 'AddToGroup') | Should -BeGreaterThan ([array]::LastIndexOf($types, 'CreateUser'))
        [array]::IndexOf($types, 'SetManager') | Should -BeGreaterThan ([array]::LastIndexOf($types, 'AddToGroup'))
    }

    It 'does nothing when the tenant already matches (idempotent re-run)' {
        @(Compare-IdentityState -Desired $Day1 -Current (New-TenantFromDesired $Day1)).Count | Should -Be 0
    }

    Context 'day 1 to day 2' {
        BeforeAll { $script:Actions = @(Compare-IdentityState -Desired $Day2 -Current (New-TenantFromDesired $Day1)) }

        It 'updates the 6 movers' {
            @($Actions | Where-Object Type -eq UpdateAttributes).EmployeeId | Sort-Object |
                Should -Be @('E008', 'E009', 'E017', 'E022', 'E029', 'E040')
        }

        It 'disables the 4 leavers' {
            @($Actions | Where-Object Type -eq DisableUser).EmployeeId | Sort-Object |
                Should -Be @('E015', 'E025', 'E037', 'E043')
        }

        It 'strips every Warden group from leavers' {
            $removed = @($Actions | Where-Object { $_.Type -eq 'RemoveFromGroup' -and $_.EmployeeId -eq 'E015' }).Group
            $removed | Sort-Object | Should -Be @('warden-all-staff', 'warden-engineering', 'warden-source-control')
        }

        It 'swaps groups for a department move but keeps shared access' {
            $e022 = @($Actions | Where-Object EmployeeId -eq 'E022')
            ($e022 | Where-Object Type -eq AddToGroup).Group | Should -Be 'warden-marketing'
            ($e022 | Where-Object Type -eq RemoveFromGroup).Group | Should -Be 'warden-sales'
            $e022.Group | Should -Not -Contain 'warden-crm'
        }

        It 'records old and new values for a title change' {
            $u = $Actions | Where-Object { $_.Type -eq 'UpdateAttributes' -and $_.EmployeeId -eq 'E009' }
            $u.Details.Changes['jobTitle'] | Should -Be 'Senior Software Engineer'
            $u.Details.Previous['jobTitle'] | Should -Be 'Software Engineer'
        }

        It 'never deletes accounts' {
            $Actions.Type | Should -Not -Contain 'DeleteUser'
        }

        It 'does nothing on a second day 2 run' {
            @(Compare-IdentityState -Desired $Day2 -Current (New-TenantFromDesired $Day2)).Count | Should -Be 0
        }
    }

    It 'does not revoke sessions again for an already disabled leaver' {
        $tenant = New-TenantFromDesired $Day2
        @(Compare-IdentityState -Desired $Day2 -Current $tenant | Where-Object Type -eq DisableUser).Count | Should -Be 0
    }

    It 're-enables a rehired employee' {
        $tenant = New-TenantFromDesired $Day1
        ($tenant.Users | Where-Object EmployeeId -eq 'E020').AccountEnabled = $false
        @(Compare-IdentityState -Desired $Day1 -Current $tenant).Type | Should -Be @('EnableUser')
    }

    It 'removes a Warden group that was added by hand' {
        $tenant = New-TenantFromDesired $Day1
        ($tenant.Users | Where-Object EmployeeId -eq 'E020').Groups += 'warden-finance'
        $a = @(Compare-IdentityState -Desired $Day1 -Current $tenant)
        $a.Type | Should -Be @('RemoveFromGroup')
        $a.Group | Should -Be 'warden-finance'
    }

    It 'leaves accounts it does not manage alone' {
        $tenant = New-TenantFromDesired $Day1
        $tenant.Users += [pscustomobject]@{
            Id = 'id-admin'; EmployeeId = $null; UserPrincipalName = 'admin@contoso.onmicrosoft.com'; DisplayName = 'Admin'
            GivenName = $null; Surname = $null; Department = $null; JobTitle = $null; AccountEnabled = $true
            ManagerId = $null; Groups = @(); Managed = $false
        }
        @(Compare-IdentityState -Desired $Day1 -Current $tenant).Count | Should -Be 0
    }

    It 'reports a conflict instead of taking over an existing UPN' {
        $tenant = [pscustomobject]@{ Groups = @{}; GroupMembers = @{}; Users = @([pscustomobject]@{
                    Id = 'id-x'; EmployeeId = $null; UserPrincipalName = 'Priya.Raman@contoso.onmicrosoft.com'; DisplayName = 'Priya'
                    GivenName = $null; Surname = $null; Department = $null; JobTitle = $null; AccountEnabled = $true
                    ManagerId = $null; Groups = @(); Managed = $false
                }) }
        $a = @(Compare-IdentityState -Desired $Day1 -Current $tenant | Where-Object EmployeeId -eq 'E001')
        $a.Type | Should -Be @('Conflict')
    }

    It 'corrects a manager that does not match HR' {
        $tenant = New-TenantFromDesired $Day1
        ($tenant.Users | Where-Object EmployeeId -eq 'E020').ManagerId = 'unmanaged:abc'
        $a = @(Compare-IdentityState -Desired $Day1 -Current $tenant)
        $a.Type | Should -Be @('SetManager')
        $a.Details.ManagerId | Should -Be 'E003'
    }
}

Describe 'Get-AccessDrift' {
    BeforeAll { $script:Day1 = Get-Desired 'hr_day1.csv' }

    It 'finds nothing when the tenant matches HR' {
        @(Get-AccessDrift -Desired $Day1 -Current (New-TenantFromDesired $Day1)).Count | Should -Be 0
    }

    It 'flags <Finding>' -ForEach @(
        @{ Finding = 'UnmanagedMember' }
        @{ Finding = 'OrphanAccount' }
        @{ Finding = 'EnabledLeaver' }
        @{ Finding = 'ExcessAccess' }
        @{ Finding = 'MissingAccess' }
    ) {
        $tenant = New-TenantFromDesired $Day1
        $desired = $Day1
        switch ($Finding) {
            'UnmanagedMember' {
                $tenant.Users += [pscustomobject]@{ Id = 'id-intruder'; EmployeeId = $null; UserPrincipalName = 'temp@contoso.onmicrosoft.com'
                    DisplayName = 'Temp'; GivenName = $null; Surname = $null; Department = $null; JobTitle = $null
                    AccountEnabled = $true; ManagerId = $null; Groups = @('warden-erp'); Managed = $false }
                $tenant.GroupMembers['warden-erp'].Add('id-intruder')
            }
            'OrphanAccount' { $desired = @($Day1 | Where-Object EmployeeId -ne 'E050') }
            'EnabledLeaver' {
                $desired = @($Day1 | ForEach-Object {
                        if ($_.EmployeeId -eq 'E050') { $c = $_.PSObject.Copy(); $c.Active = $false; $c.Groups = @(); $c } else { $_ } })
            }
            'ExcessAccess' { ($tenant.Users | Where-Object EmployeeId -eq 'E020').Groups += 'warden-finance' }
            'MissingAccess' { ($tenant.Users | Where-Object EmployeeId -eq 'E020').Groups = @('warden-all-staff') }
        }
        @(Get-AccessDrift -Desired $desired -Current $tenant).Finding | Should -Contain $Finding
    }
}

Describe 'Invoke-IdentityAction' {
    BeforeAll {
        $script:Day1 = Get-Desired 'hr_day1.csv'
        $script:Person = $Day1 | Where-Object EmployeeId -eq 'E008'
    }

    BeforeEach {
        Mock Invoke-MgGraphRequest -ModuleName Warden { @{ id = 'new-object-id' } }
        $script:Context = @{
            UserIds  = @{ E008 = 'uid-8'; E002 = 'uid-2' }
            GroupIds = @{ 'warden-engineering' = 'gid-eng' }
            Desired  = @{ E008 = $Person }
        }
    }

    It 'makes no Graph calls in dry-run mode' {
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'DisableUser'; EmployeeId = 'E008'; Group = $null; Details = @{} }) -Context $Context -DryRun
        $r.Status | Should -Be 'DryRun'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 0
    }

    It 'creates a user with the ownership marker and a password it never returns' {
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'CreateUser'; EmployeeId = 'E008'; Group = $null; Details = @{} }) -Context @{
            UserIds = @{}; GroupIds = @{}; Desired = @{ E008 = $Person } }
        $r.Status | Should -Be 'Applied'
        ($r | ConvertTo-Json) | Should -Not -Match 'password'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $b = $Body | ConvertFrom-Json
            $Method -eq 'POST' -and $Uri -like '*/users' -and $b.companyName -eq 'Warden Labs' -and
            $b.employeeId -eq 'E008' -and $b.passwordProfile.password.Length -eq 24 -and $b.passwordProfile.forceChangePasswordNextSignIn
        }
    }

    It 'disables the account and then revokes its sessions' {
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'DisableUser'; EmployeeId = 'E008'; Group = $null; Details = @{} }) -Context $Context
        $r.Status | Should -Be 'Applied'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $Method -eq 'PATCH' -and $Uri -like '*/users/uid-8' -and ($Body | ConvertFrom-Json).accountEnabled -eq $false }
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/users/uid-8/revokeSignInSessions' }
    }

    It 'adds a group member by reference' {
        Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'AddToGroup'; EmployeeId = 'E008'; Group = 'warden-engineering'; Details = @{} }) -Context $Context |
            Select-Object -ExpandProperty Status | Should -Be 'Applied'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $Uri -like '*/groups/gid-eng/members/$ref' -and ($Body | ConvertFrom-Json).'@odata.id' -like '*/directoryObjects/uid-8' }
    }

    It 'sets the manager by reference' {
        Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'SetManager'; EmployeeId = 'E008'; Group = $null; Details = @{ ManagerId = 'E002' } }) -Context $Context | Out-Null
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $Method -eq 'PUT' -and $Uri -like '*/users/uid-8/manager/$ref' -and ($Body | ConvertFrom-Json).'@odata.id' -like '*/users/uid-2' }
    }

    It 'returns a failure instead of throwing when Graph errors' {
        Mock Invoke-MgGraphRequest -ModuleName Warden { throw 'Insufficient privileges' }
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'EnableUser'; EmployeeId = 'E008'; Group = $null; Details = @{} }) -Context $Context
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'Insufficient privileges'
    }

    It 'retries a not-found error caused by replication delay' {
        InModuleScope Warden { $script:ReplicationDelaySeconds = 0 }
        $script:calls = 0
        Mock Invoke-MgGraphRequest -ModuleName Warden {
            $script:calls++
            if ($script:calls -lt 3) { throw 'Response status code does not indicate success: 404 (NotFound).' }
            @{}
        }
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'AddToGroup'; EmployeeId = 'E008'; Group = 'warden-engineering'; Details = @{} }) -Context $Context
        $r.Status | Should -Be 'Applied'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 3 -Exactly
    }

    It 'does not retry other errors' {
        Mock Invoke-MgGraphRequest -ModuleName Warden { throw '403 (Forbidden)' }
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'EnableUser'; EmployeeId = 'E008'; Group = $null; Details = @{} }) -Context $Context
        $r.Status | Should -Be 'Failed'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -Exactly
    }

    It 'fails clearly when a group has not been created' {
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'AddToGroup'; EmployeeId = 'E008'; Group = 'warden-unknown'; Details = @{} }) -Context $Context
        $r.Error | Should -Match 'does not exist'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 0
    }

    It 'skips conflicts without calling Graph' {
        $r = Invoke-IdentityAction -Action ([pscustomobject]@{ Type = 'Conflict'; EmployeeId = 'E008'; Group = $null; Details = @{ Reason = 'taken' } }) -Context $Context
        $r.Status | Should -Be 'Skipped'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 0
    }
}

Describe 'Get-EntraState' {
    It 'reads users and groups, follows paging, and marks ownership' {
        Mock Invoke-MgGraphRequest -ModuleName Warden -ParameterFilter { $Uri -like '*/users?*' } {
            @{ value = @(
                    @{ id = 'u1'; userPrincipalName = 'a@x.com'; employeeId = 'E001'; companyName = 'Warden Labs'; accountEnabled = $true; manager = $null }
                    @{ id = 'u2'; userPrincipalName = 'b@x.com'; employeeId = 'E002'; companyName = 'Warden Labs'; accountEnabled = $true; manager = @{ id = 'u1' } }
                ); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users-page-2' }
        }
        Mock Invoke-MgGraphRequest -ModuleName Warden -ParameterFilter { $Uri -like '*users-page-2' } {
            @{ value = @(@{ id = 'u3'; userPrincipalName = 'admin@x.com'; employeeId = $null; companyName = $null; accountEnabled = $true; manager = @{ id = 'u9' } }) }
        }
        Mock Invoke-MgGraphRequest -ModuleName Warden -ParameterFilter { $Uri -like '*/groups?*' } {
            @{ value = @(@{ id = 'g1'; displayName = 'warden-crm' }) }
        }
        Mock Invoke-MgGraphRequest -ModuleName Warden -ParameterFilter { $Uri -like '*/groups/g1/members*' } {
            @{ value = @(@{ id = 'u2' }, @{ id = 'u3' }) }
        }

        $state = Get-EntraState -GroupPrefix 'warden-'

        $state.Users.Count | Should -Be 3
        ($state.Users | Where-Object Id -eq 'u2').ManagerId | Should -Be 'E001'
        ($state.Users | Where-Object Id -eq 'u2').Groups | Should -Be @('warden-crm')
        ($state.Users | Where-Object Id -eq 'u3').Managed | Should -BeFalse
        ($state.Users | Where-Object Id -eq 'u3').ManagerId | Should -Be 'unmanaged:u9'
        $state.Groups['warden-crm'] | Should -Be 'g1'
        Should -Invoke Invoke-MgGraphRequest -ModuleName Warden -Times 1 -ParameterFilter {
            $Uri -like '*/groups?*' -and [uri]::UnescapeDataString($Uri) -like "*startswith(displayName,'warden-')*" }
    }
}

Describe 'Invoke-WardenSync' {
    BeforeAll {
        $script:Hr1 = Import-HrRecords -Path "$Root/data/hr_day1.csv"
        $script:Day1 = Get-Desired 'hr_day1.csv'
    }

    It 'writes one JSON audit line per action and changes nothing in dry-run' {
        Mock Get-EntraState -ModuleName Warden { [pscustomobject]@{ Users = @(); Groups = @{}; GroupMembers = @{} } }
        Mock Invoke-MgGraphRequest -ModuleName Warden { throw 'should not be called' }
        $audit = Join-Path $TestDrive 'audit.jsonl'

        $result = Invoke-WardenSync -HrRecords $Hr1 -RoleMap $RoleMap -UpnDomain $Domain -DryRun -AuditPath $audit

        $lines = @(Get-Content $audit | ForEach-Object { $_ | ConvertFrom-Json })
        $lines.Count | Should -Be $result.Actions.Count
        $lines.Count | Should -Be 248
        ($lines.status | Sort-Object -Unique) | Should -Be 'DryRun'
        ($lines.runId | Sort-Object -Unique) | Should -Be $result.RunId
        $result.Counts['CreateUser'] | Should -Be 50
        $result.Failed | Should -Be 0
        Get-Content $audit -Raw | Should -Not -Match 'password'
    }

    It 'reports zero actions when the tenant is already in sync' {
        Mock Get-EntraState -ModuleName Warden { New-TenantFromDesired $Day1 }
        $result = Invoke-WardenSync -HrRecords $Hr1 -RoleMap $RoleMap -UpnDomain $Domain
        $result.Actions.Count | Should -Be 0
        $result.Drift.Count | Should -Be 0
    }
}
