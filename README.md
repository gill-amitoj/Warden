# Warden: Identity Lifecycle Automation for Entra ID

Warden keeps Microsoft Entra ID in sync with an HR export. New hires get an
account and the right access, people who change roles get their access
swapped, and leavers are disabled and signed out everywhere. Every change is
written to an audit log.

It's a PowerShell module on top of Microsoft Graph, tested with Pester, and
deployed as a daily Azure Function that signs in with a managed identity.

---

## The problem

Joiner-mover-leaver (JML) is the core of identity management, and doing it by
hand goes wrong in predictable ways:

- **Leavers keep access.** An account that isn't disabled on someone's last
  day is a live credential nobody is watching.
- **Movers pile up access.** People who change teams get new groups added
  but old ones rarely removed, so access only ever grows.
- **Nobody can say who changed what.** Without an audit trail, access reviews
  turn into guesswork.

Warden treats the HR export as the source of truth and makes Entra match it,
safely enough to run unattended every day.

---

## How it works

```
HR export (CSV) ──► Import-HrRecords      validate every field (untrusted input)
                          │
config/roles.json ──► Get-DesiredState    who should exist, with which groups
                          │
Entra ID (Graph) ──► Get-EntraState       who exists now, in which groups
                          │
                    Compare-IdentityState pure function: ordered list of actions
                    Get-AccessDrift       report of every mismatch
                          │
                    Invoke-IdentityAction one Graph call per action (-DryRun: none)
                          │
                    audit log (JSON lines) + drift report
```

| Event | What Warden does |
|---|---|
| **Joiner** | Creates the account (random password, forced change), adds role groups, sets the manager |
| **Mover** | Updates department and title, adds new role groups, removes old ones, updates the manager |
| **Leaver** | Disables the account, **revokes all sign-in sessions**, removes every Warden group. The account is **kept, not deleted**, for audit |
| **Rehire** | Re-enables the existing account instead of creating a duplicate |

## Design decisions

- **Users are matched on `employeeId`, not name.** A name change or a move
  never creates a second account. Two people called Alex Kim get distinct
  UPNs (`alex.kim.e009`, `alex.kim.e010`).
- **Warden only touches accounts it owns.** Accounts it creates carry
  `companyName = "Warden Labs"`. Admins and manually created users are read
  but never modified, and Warden won't take over an existing UPN (it reports
  a conflict instead). It only ever removes memberships of `warden-` groups.
- **Decide first, then act.** `Compare-IdentityState` makes no calls and
  returns a list of actions. That's what makes the logic testable, makes
  dry-run trivial, and makes re-runs idempotent: an in-sync tenant produces
  an empty list.
- **Leavers are disabled, not deleted.** Deletion destroys the audit trail
  and is hard to undo for a rehire; a disabled account with no group access
  can't be used.
- **Disable *and* revoke.** Disabling stops new sign-ins; revoking ends the
  sessions and refresh tokens that are already out there.
- **Untrusted input is validated.** HR fields must match strict patterns
  before they reach Graph, and values used in OData filters go through
  `ConvertTo-ODataLiteral`, so a name like `O'Brien` (or a crafted
  `x' or 1 eq 1`) stays a single string literal.
- **Least privilege.** The scheduled job's managed identity has exactly two
  Graph application permissions: `User.ReadWrite.All` and
  `GroupMember.ReadWrite.All`. Creating groups is a separate one-time admin
  step, so the daily job never needs `Group.ReadWrite.All`.
- **Replication delay is handled.** Entra can briefly return 404 for an object
  created a moment ago; not-found responses are retried with backoff, other
  errors are not.

---

## Results

Run against a real Entra ID tenant with 50 synthetic employees:

| Run | Actions | Outcome |
|---|---|---|
| Day 1 | 50 users created, 149 group memberships, 49 managers set | 248/248 applied, 0 failed |
| Day 1 again | none | "No changes needed" (idempotent) |
| Day 2 (6 role changes, 4 departures) | 6 updates, 7 group adds, 19 removals, 4 manager changes, 4 disables with session revocation | 40/40 applied; drift went from 30 findings to 0 |
| Day 2 again | none | "No changes needed" |
| Azure Function (managed identity) | none | Signed in with the managed identity, read the tenant, 0 drift |

The HR data covers the awkward cases on purpose: an apostrophe (Siobhan
O'Brien), accents (José Álvarez), a hyphen (Mary-Kate Lin), duplicate names,
and a Sales → Marketing move where shared CRM access must be kept.

**60 Pester tests** cover validation, UPN generation, every JML path,
idempotency, drift findings, the OData guard, retry behaviour, and the Graph
calls themselves (mocked), including that dry-run makes no calls and that
passwords never reach the audit log.

---

## Running it

Requires PowerShell 7.4+, Pester 5+, and `Microsoft.Graph.Authentication`.

```powershell
Install-Module Pester, Microsoft.Graph.Authentication -Scope CurrentUser
Invoke-Pester ./tests

Connect-MgGraph -Scopes 'User.ReadWrite.All','GroupMember.ReadWrite.All','Group.ReadWrite.All'
./scripts/Initialize-WardenGroups.ps1                     # once: creates the warden- groups
./scripts/Invoke-Warden.ps1 -HrCsvPath ./data/hr_day1.csv -UpnDomain <tenant>.onmicrosoft.com -DryRun
./scripts/Invoke-Warden.ps1 -HrCsvPath ./data/hr_day1.csv -UpnDomain <tenant>.onmicrosoft.com
```

Each run writes `logs/audit-<time>-<mode>.jsonl` (one JSON object per action,
with old and new values) and `logs/drift-<time>.json`.

### Daily schedule in Azure

```powershell
az login
./infra/Deploy-Warden.ps1 -UpnDomain <tenant>.onmicrosoft.com -HrCsvPath ./data/hr_day2.csv -RunNow
```

This deploys [`infra/main.bicep`](infra/main.bicep): a Consumption-plan
Function App with a system-assigned managed identity and a timer trigger
(06:00 UTC daily), grants the identity its two Graph permissions, uploads the
code, and triggers one run. It deploys in dry-run mode; add `-Live` to let it
make changes. Each run's audit log lands in the `audit` blob container.

I first targeted Azure Automation, but Azure for Students subscriptions can't
create Automation accounts in any region their policy allows, so the job runs
as a timer-triggered Function instead. It's the same model: serverless, a
managed identity, no stored secrets.

```powershell
az group delete -n warden-rg --yes   # tear down
```

---

## Project structure

```
src/Warden.psm1                 all logic (validation, compare, drift, Graph calls)
tests/Warden.Tests.ps1          Pester tests
scripts/Invoke-Warden.ps1       run a sync from your machine
scripts/Initialize-WardenGroups.ps1
config/roles.json               department -> groups
data/hr_day1.csv, hr_day2.csv   synthetic HR exports
function/                       Azure Function (timer trigger)
infra/                          Bicep + deploy script
```

All employee data in this repository is synthetic.
