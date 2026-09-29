# Workforce

Module ID: `people/workforce`. Public workforce identity and read contracts.

`company/2`, `employees/2`, `employee/3`, and `positions/2` require a validated
`Bilimbi.Base.Tenancy.Scope` and explicit platform company ID. Native workforce
company identity maps to Core Company today, but the two axes remain distinct.
References use stable `people/native` source identity and immutable native IDs.
Employee identity never implies a login actor.

Company and employee reads use Core public APIs and return current `Snapshot`
values. Only active companies and active non-agent employees are exposed.
Missing, cross-tenant, archived, and malformed company IDs are indistinguishable.
Position reads return `{:error, :unavailable}` for a valid company until
Organisation publishes a position API. `Snapshot.require_current/1` refuses
stale and unavailable provider results. There is no native stale cache or
fallback. This module owns no tables, routes, menu entries, or Connector imports.
