# Workforce

Module ID: `people/workforce`. Public workforce identity and read contracts.

`company/2`, `employees/2`, `employee/3`, `working_statuses/2`, and
`put_working_statuses/3` require a validated `Bilimbi.Base.Tenancy.Scope` and
explicit platform company ID. Native workforce company identity maps to Core
Company today, but the two axes remain distinct. References use stable
`people/native` source identity and immutable native IDs. Employee identity
never implies a login actor.

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
