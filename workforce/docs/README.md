# Workforce

Module ID: `people/workforce`. Public workforce identity and read contracts.

`company/2`, `employees/2`, `employee/3`, `working_statuses/2`, and
`put_working_statuses/3` require a validated `Bilimbi.Base.Tenancy.Scope` and
explicit platform company ID. Read functions return `ReadResult` values:
native reads are `:current`, `stale/2` carries the last confirmation time, and
`unavailable/1` carries a reason. Call `ReadResult.require_current/1` to obtain
the value only when it is current; stale and unavailable results return a
`:not_current` refusal. `people/attendance` consumes this seam, and the People
connector contract in the separate `b-dom-people-connector` repository
(slice 1C) will too. The settings page shows a notice for stale or unavailable reads. Native
workforce company identity maps to Core Company today, but the two axes remain
distinct. References use stable `people/native` source identity and immutable
native IDs. Employee identity never implies a login actor.

`positions/4` uses the same company boundary and returns bounded position
projections when Organisation is mounted. Organisation registers that public
reader during application startup; an absent owner returns
`{:error, :unavailable}`. Position references use the native source identity
and remain distinct from Connector projections.

Company and employee reads use Core public APIs. Only active companies and
non-agent employees in the company's working statuses are exposed, both as
employees and as supervisor references. Missing, cross-tenant, archived, and
malformed company IDs are indistinguishable.

Working statuses are the company-scoped Base Setting
`people.workforce.working_statuses`, defaulting to `probation` and `active`. A
value must be a non-empty subset of Core Employee statuses. Operators holding
`people.workforce.settings.manage` edit it per company at
`/people/workforce/settings`; the page has no menu leaf until the People
navigation outline lands. This module owns no tables or Connector imports.
