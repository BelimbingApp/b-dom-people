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

Company and employee reads use Core public APIs. Only active companies and
non-agent employees in the company's working statuses are exposed, both as
employees and as supervisor references. `employees_by_ids/3` applies the same
rule to at most 1,000 employee IDs without reading the whole workforce.
Missing, cross-tenant, archived, and malformed company IDs are
indistinguishable.

## Per-operation authorization

`Bilimbi.People.Workforce.Authorization` is the one boundary every People
facade authorizes through, at the public API so LiveViews, jobs and other
adapters share it. `authorize/3` evaluates a capability now for the scope's
sealed actor and the explicit company, through `Bilimbi.Base.Authz` and
`Bilimbi.Core.Company.authorize_company_target/3` with the scope, not an
actor taken from it; a system scope is refused.
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
value must be a non-empty subset of Core Employee statuses. Operators holding
`people.workforce.settings.manage` edit it per company at
`/people/workforce/settings`; the page has no menu leaf until the People
navigation outline lands. This module owns no tables or Connector imports.
