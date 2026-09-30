# Payroll foundation

`people/payroll` owns fresh Bilimbi periods, effective-dated classifications,
pay items, Leave/Claims mappings and frozen setup runs. It installs no sample
rows, statutory packs, country rules or bank formats. Calculation, contribution
intake, approvals, artifacts and output belong to slice 6A.

The authenticated `/people/payroll/setup` route requires
`people.payroll.view`. Editing requires `people.payroll.manage` both in the
LiveView event guard and the public facade. Payroll navigation remains hidden
until the whole payroll area meets its acceptance. Operators reach this route
directly for foundation review. Company selection comes from Core Company's
public selectable-company API. APIs require a validated tenant scope with a
sealed login actor; sibling companies require explicit tenant-wide reach.
Anonymous/system actors, impersonated writes, archived companies and other
tenants are refused. No actor identifier can be submitted in record fields.

## Operator setup

Choose a country identifier and allowed three-letter currency codes for one
platform company. These are Base Settings (`people.payroll.country` and
`people.payroll.currencies`), also available on the setup page. Defaults are
empty: no country or currency is presumed and no statutory pack activates.

Add classification versions, then pay-item versions with the classification,
exact amount and explicit currency. Amounts use PostgreSQL `numeric(20,6)` and
Decimal, never floating point. More than six fractional digits, negative values
and overflow are refused instead of silently rounded.

Definitions and mappings are append-only. Versions of the same code or source
must not overlap. Use bounded effective dates when future policy changes are
expected; an open-ended version intentionally cannot be replaced. A pay item
must fit within its classification's dates; a mapping must fit within its pay
item's dates. Dates are inclusive. Periods cannot overlap and their explicit pay
date must be on or after the end date.

Leave and Claims choices are read through the owning modules' public catalogs.
A submitted source key must belong to the selected company. Attendance is
labelled **not available yet** and cannot be mapped: the allowance catalog and
payroll source API are a separate Attendance follow-up slice. Clocking settings
are not allowance rules.

Freeze setup for a period and currency. The snapshot stores period, applicable
versions, decimal amount strings, country and currency, ordered by stable IDs.
Only mappings for that currency's items are included. Each period/currency has
one run. Subsequent settings or future versions cannot alter its snapshot.
Locking records the authenticated actor and is irreversible. PostgreSQL rejects
updates/deletes of locked runs, deleting any run, and changing a draft run
except its initial lock. Classification, item, period and mapping rows are also
protected against updates/deletes by PostgreSQL. A company-scoped advisory
transaction lock serializes facade writes, overlap checks and snapshots.

## Schema and validation

Migration `20260930230501` is `:bilimbi_only`. The unregistered
`Bilimbi.People.Payroll.SchemaContract` is checked after fresh migration with
`Bilimbi.Base.Database.SchemaVerifier.verify/2`. Registration remains nil because
pre-migration compatibility verification must not demand new tables.

Development verification uses a new isolated scratch database, never legacy
People adoption. Before either deployment, inventory the actual target database
read-only for `people_payroll_%` relations and row counts. Record both environment
results in the deployment record; unexpected live rows require a new migration
decision. Local empty scratch results do not certify production inventory.

Focused tests exercise the real Web host, authorization, forged events,
company/tenant denial, setup workflows, exact decimals, version overlap, source
validation, snapshots and database refusal of locked-run mutation. Fresh-schema
verification and direct trigger checks cover the actual migrated relations,
separately from temporary host fixtures.
