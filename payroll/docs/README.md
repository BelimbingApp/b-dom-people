# Payroll foundation

`people/payroll` owns fresh Bilimbi periods, effective-dated classifications,
pay items, Leave/Claims and Attendance allowance mappings and frozen setup
runs. It installs no sample rows, statutory packs, country rules or bank
formats. Calculation, contribution intake, approvals, artifacts and output
belong to slice 6A.

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

Definitions and mappings are append-only. Versions of the same code must not
overlap. A source may map once per currency: its mapping versions must not
overlap for pay items in the same currency. Use bounded effective dates when
future policy changes are expected; an open-ended version intentionally cannot
be replaced. A pay item
must fit within its classification's dates; a mapping must fit within its pay
item's dates. Dates are inclusive. Periods cannot overlap and their explicit pay
date must be on or after the end date.

Leave and Claims choices are read through the owning modules' public catalogs.
A submitted source key must belong to the selected company. Attendance
allowance rules cannot be mapped here; operators with the attendance mapping
capability see a link to the separate mapping page described below. Clocking
settings are not allowance rules.

Freeze setup for a period and currency. The snapshot stores period, applicable
versions, decimal amount strings, country and currency, ordered by stable IDs.
Only mappings for that currency's items are included. Leave and Claims sources
with no mapping for that currency in the period are listed as unmapped in the
snapshot and on the run: every active leave and claim type, plus any archived or
inactive type that still has a pending or approved leave request, or a claim
that is not withdrawn or rejected, in the period. Activity is read through
`Leave.requested_type_ids/4` and `Claims.requested_claim_type_ids/4`. When
Workforce data is not current those reads are refused, and the run reports that
cause instead of freezing. Each period/currency has
one run. Subsequent settings or future versions cannot alter its snapshot.
Locking records the authenticated actor and is irreversible. PostgreSQL rejects
updates/deletes of locked runs, deleting any run, and changing a draft run
except its initial lock. Classification, item, period and both mapping tables
are also protected against updates/deletes by PostgreSQL. A company-scoped
advisory transaction lock serializes facade writes, overlap checks and
snapshots.

## Attendance allowance mappings

Attendance allowance rules are read through
`Bilimbi.People.Attendance.list_allowance_rules/2`; Payroll does not read
Attendance tables. The mapping page offers every active rule version that has
not ended, including future-effective versions. Operators
with `people.payroll.attendance-mappings.manage` map an allowance rule code to
an existing company pay item at `/people/payroll/attendance-mappings`. Every
facade function checks that capability, a signed-in non-impersonated user and
an active company. The route has no menu contribution while this area remains
under acceptance.

Attendance mappings follow the same append-only, effective-dated model as
Leave/Claims mappings: an active version of the rule code must be effective
within the mapping dates, every such version must use the pay item's currency,
the pay item must cover the whole mapping period, and versions of one rule code
for the same currency cannot overlap. They are keyed by rule code, so a new Attendance rule
version keeps its mapping. PostgreSQL refuses updates and deletes, and a run
freezes the effective attendance mappings for its currency under
`attendance_mappings` in the snapshot. Active allowance rules in the run
currency that are effective in the period but have no mapping are reported in
`unmapped_sources` with source kind `attendance` and the rule code as key.
When a rule version effective in the run period and mapping dates has another
currency, the run leaves that mapping out and reports the rule code under
`unmapped_sources` with reason `currency mismatch`.

## Schema and validation

Migrations `20260930230501` and `20260930230502` are `:bilimbi_only`. The unregistered
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
validation, per-currency mappings, unmapped-source reports and snapshots.
`web_test/payroll_migration_test.exs` runs the real migration in a new scratch
database, verifies it with `SchemaVerifier.verify/2`, and checks that its
triggers, foreign keys and unique indexes refuse invalid changes, including any
change to a locked run.
