# Workforce

Module ID: `people/workforce`. Public workforce identity and read contracts.

`company/2`, `employees/2`, `employee/3`, `employees_by_ids/3`,
`working_statuses/2`, and `put_working_statuses/3` require a validated
`Bilimbi.Base.Tenancy.Scope` and explicit platform company ID. Read functions
return `ReadResult` values: native reads are `:current`, `stale/2` carries the
last confirmation time, and `unavailable/1` carries a reason. Call
`ReadResult.require_current/1` to obtain the value only when it is current;
stale and unavailable results return a `:not_current` refusal.
`people/attendance` and `people/leave` consume this seam, and the People
connector contract in the separate `b-dom-people-connector` repository
(slice 1C) will too. The settings page shows a notice for stale or unavailable
reads. Native workforce company identity maps to Core Company today, but the
two axes remain distinct. References use stable `people/native` source identity
and immutable native IDs. Employee identity never implies a login actor.

`positions/4` uses the same company boundary and returns a current `ReadResult`
of bounded position projections when Organisation is mounted. Organisation
registers that public reader during application startup; an absent owner returns
`{:error, :unavailable}`. Position references use the native source identity and
remain distinct from Connector projections.
`positions_available?/0` returns true only while a position reader is registered.

For a full position scan, call `positions(scope, company_id, as_of,
cursor: nil, page_size: 50)`. The current `ReadResult.value` is a map with
`positions`, `next_cursor`, and `high_water_id`. Pass each non-nil
`next_cursor` back as `cursor:` with the same scope, company and date; stop
when `next_cursor` is nil. Page size defaults to 50 and accepts integers from
1 through 100, including a different size on subsequent pages. Cursors are
opaque URL-safe strings; malformed cursors or a different tenant, company or
date return `{:error, :invalid_cursor}`. Cursors do not grant access: every
page rechecks the live company boundary. Mixing `cursor:` and `page:` returns
`{:error, :invalid_options}`.

The first cursor page fixes the high-water mark: the last position ID issued
by the positions ID sequence (zero before any position exists). It is
monotonic, so deleting the highest-ID position never lowers it, and it may
exceed the company's own highest ID. Every page reads the company's IDs
strictly above the last returned ID and at or below this mark, ordered by the
unique immutable ID. The same `high_water_id` is returned on every page, even
an empty final page after deletions. Inserts above the mark wait for the next
full scan; deleting earlier rows never shifts later pages, and unread deleted
rows, including the highest-ID one, are absent at or below the mark. Surviving
positions are never skipped or duplicated. This is an ID boundary, not a
historical snapshot: projections are read at each page, and a transaction
that allocated an ID below the mark but commits later can become visible.

Only after successfully reading every page with current freshness should a
consumer deactivate missing native positions, and only those whose native
position IDs are **at or below `high_water_id`**. Preserve positions above it;
never reconcile absence from an incomplete, unavailable or failed scan.
Use the same explicit `as_of` throughout a scan, including one spanning
midnight. Existing calls without `cursor:` retain their list-valued result
and `page:` / `page_size:` offset behavior for the explorer.

Company and employee identity reads use Core public APIs. Employment numbers,
types, statuses and dates come from People's employment records (see below).
Only active companies and non-agent employees in the company's working
statuses are exposed, both as employees and as supervisor references.
`employees_by_ids/3` applies the same rule to at most 1,000 employee IDs
without reading the whole workforce.
Missing, cross-tenant, archived, and malformed company IDs are
indistinguishable.

## Per-operation authorization

`Bilimbi.People.Workforce.Authorization` is the one boundary every People
facade authorizes through, at the public API so LiveViews, jobs and other
adapters share it. `authorize/3` evaluates a capability now for the scope's
sealed actor and the explicit company, through `Bilimbi.Base.Authz` and
`Bilimbi.Core.Company.authorize_company_target/3` with that same resolved
actor, never an actor argument from the caller; a system scope is refused.
`authorize_company/3` and `selectable_companies/2` do the same for a page
that needs the company summary or the companies an operator may pick.
`self_employee/2` resolves the login account's current link to a working
employee on every call, `authorize_self/3` combines both, and
`with_self_employee_lock/4` runs a self-service write inside a transaction
that holds the Core Employee affiliation lock and proves the link again under
it, so an unlinked or relinked account cannot act on its former employee.
`put_working_statuses/3` requires `people.workforce.settings.manage` this way.
Facades return `:unauthorized` and `:not_linked`; a `can_*?` assign only
decides which controls a page renders. Tests sign a user in with the shared
`Bilimbi.People.Workforce.AuthorizationFixtures`.

Working statuses are the company-scoped Base Setting
`people.workforce.working_statuses`, defaulting to `probation` and `active`. A
value must be a non-empty subset of the employment statuses. Operators holding
`people.workforce.settings.manage` edit it per company at
`/people/workforce/settings`; the page has no menu leaf until the People
navigation outline lands. This module owns no Connector imports.

## Employment records

People owns employee numbers, employment types, statuses, employment start
and end dates, and the HR metadata that came with them. One row of
`people_workforce_employments` is one employment. It references the Core
Person (`person_id`) and that person's affiliation with the employer
(`affiliation_id`); the employer company is the affiliation's company. Names,
email, phone and titles stay in Core Person and are not copied. Migrations
`20261016090000` and `20261016093000` are fresh `:bilimbi_only` schema with no
rows; `Bilimbi.People.Workforce.SchemaContract` stays unregistered and
`test/schema_contract_test.exs` verifies it against a freshly migrated
database.

`legacy_employee_id` is the explicit mapping from the legacy Core Employee
row. Every People module still keys employees on that ID, as do Core User
links, principal grants and system-agent references, so it stays the
employee's durable reference. `legacy_created_at` keeps the Core row's
creation time and `claimed_at` records when People took the row over.

Use `Workforce.employment/3` (capability `people.workforce.employment.view`)
for an employee's facts, at any status and including agents. It returns a
`Bilimbi.People.Workforce.Employment` whose `source` is `:people` (claimed),
`:legacy_drift` (claimed, then changed through Core's deprecated HR path; see
below) or `:core_legacy` (not claimed yet). `employment_summary/2` counts the
company's employees by source. Do not read these facts from
`Bilimbi.Core.Employee` summaries in a People module. A module that already
authorized reading Core summaries with its own capability (the employee
workbench, Claims' assignable and export rows) passes them through
`Workforce.with_employment_facts/2`, which swaps in the facts People
resolves; the working-staff reads (`employees/2`, `employees_by_ids/3`,
`employee/3`) resolve from People already.

### Claiming the legacy rows

The `people/workforce/employment-backfill` production seed claims every
existing Core Employee row into People. Run it with `mix bilimbi.seeds.run`
after the migrations. It walks every tenant and every live company with the
system scope, copies values verbatim (agents and every status included) and
changes nothing in Core. It is idempotent, one failing company does not stop
the others, and a failed seed is retried. Archived companies are frozen and
stay Core-only until Core publishes a tenant-wide handoff read.

The seed runs once. `Workforce.reconcile_employments/2` (capability
`people.workforce.employment.manage`, plus Core's `admin.person.view`, which
Core requires before it reveals a person mapping) re-runs the same claim for
one company: it claims rows created in Core since, and adopts Core's values
for claimed rows that drifted. A row that cannot be claimed stays Core-only
and is recorded in `people_workforce_employment_exceptions` with a reason:
`:no_person_mapping`, `:invalid_facts` (Core's number, type or status is
missing) or `:duplicate_affiliation` (another employment record already holds
the person's affiliation). The insert runs in a savepoint, so one conflict
never aborts the company. `Workforce.employment_exceptions/2` (capability
`people.workforce.employment.view`) lists them, and the workforce settings
page shows the list, the counts and a **Claim again from Core HR** action
for operators who hold the manage capability. A claim run rewrites the
company's exceptions and claiming an employee removes theirs.

### People is the writer; Core's columns are a deprecated mirror

`Workforce.update_employment/4` stores the change in People first and then
mirrors it to Core Employee's compatibility columns through
`Employee.update_employee/4`, in one transaction under the order Core uses
(company, then Core's locks, then People's record). An unclaimed employee is
claimed by the write. A value Core refuses, or a conflicting claim, rolls
back both sides and returns an error.

Core Employee keeps its HR columns, and its deprecated HR path
(`core.employee.*`, the `/employees` pages) still accepts writes. They are a
documented mirror kept for `core.employee.*` callers, integrations and the
Core User, principal-grant and system-agent references that key on the
employee ID. Removing the columns is a later, separately reviewed step, once
both the Core owner-seam change and this one have landed and no reader
remains.

Core's HR writes reach People through the employment-owner seam in Core
Employee. `Bilimbi.People.Workforce.Application` registers
`Bilimbi.People.Workforce.EmploymentOwner` at startup, but only when the Core
in use exports `register_employment_owner/1`; it is looked up by name at
runtime, so People compiles and runs against a Core without it. Core calls
`EmploymentOwner.legacy_employee_written(scope, employee_id)` inside the
transaction of each HR write, after its own locks, and People adopts the
written values, or claims the row (mapping read as the system, since Core
already authorized the write). That callback never refuses: a row it cannot
claim is recorded as an exception.

While no owner is registered, Core's deprecated path can write after the
claim. Reads then resolve to Core's newer values as `:legacy_drift` and the
next claim run adopts them; never resolve drift in People's favour, because
the Core value is the later write. Once the owner is registered the fallback
is off: a claimed row is always read from People, and `:legacy_drift` no
longer occurs. Run the claim from the settings page once after the owner is
first registered, to adopt any drift that accrued before. Unmounting People
leaves Core's columns complete, and People's tables keep their rows and
provenance.
