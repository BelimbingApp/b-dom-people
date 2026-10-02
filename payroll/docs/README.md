# Payroll foundation

`people/payroll` owns fresh Bilimbi periods, effective-dated classifications,
pay items, Leave/Claims and Attendance allowance mappings and frozen setup
runs. It installs no sample rows, statutory packs, country rules or bank
formats. Calculation, contribution intake, approvals, artifacts and output
are implemented by slice 6A below.

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

## Calculation, intake and approval

Slice 6A adds `/people/payroll/runs`, still a direct authorized route while
Payroll navigation remains hidden. The setup page links to it. Select the
platform company and frozen run, attest contributions, lock setup, calculate,
then obtain an independent final decision. `people.payroll.manage` grants
intake, calculation and document generation; `people.payroll.approve` grants
final decisions, while `people.payroll.view` grants review and private document
reads. A run creator, setup locker, calculator or contribution author cannot
approve or reject that run. Rejection is final and prevents document output;
correction requires a separately governed future period rather than overwriting
financial history. Decisions retain the sealed actor and a required reason.

`Payroll.intake/4` accepts exact decimal units, a frozen pay-item ID, the current
Workforce employee, a date inside the period and item's effective version,
a direction (`earning`, `deduction` or `employer`), a source evidence reference
and a company-unique contribution key. Actor, tenant, company and run ownership
are supplied by the facade. A repeated key with identical input returns the
accepted row while intake remains open; conflicting reuse is refused, including
reuse in another run. Calculation closes intake permanently. There are no
implicit salaries, eligibility rules, statutory percentages, country packs or
contributions. Operators attest externally governed facts; this is not an
automatic read of pending Leave/Claims requests or raw clock events.

`Payroll.intake_mapped/6` resolves Leave/Claims source IDs through the run's
frozen effective mapping. `Payroll.intake_attendance_allowance/4` resolves an
Attendance rule code through `attendance_mappings` already frozen by the
foundation. It records an earning using that mapping's pay-item rate and exact
attested units; any other attested direction is refused as
`:direction_conflict`. The allowance rule's `value` is catalog information, not a
second amount added to the pay item. Unknown, unmapped or out-of-date mappings
are refused. No allowance eligibility or units are inferred from clock data.
The page offers each intake path explicitly and requires an evidence reference.
Source owners retain their business records; no sibling private table is read
or updated and no claim is marked reimbursed by this intake contract.

`Payroll.calculate/3` requires permanently locked setup and at least one
contribution. It relies on the intake-time Workforce attestation and only
rechecks, in pages of at most 1,000, that each attested employee still belongs
to the company, whatever their current working status, so final pay for a
leaver calculates. It then atomically
stores immutable result lines and a calculation snapshot containing setup,
contributions, result and a SHA-256 replay digest of the snapshot's canonical
JSON (sorted object keys), recomputable from the stored snapshot with
`Replay.digest/1`. Retrying returns
the same calculation. Replay uses a local 60-digit Decimal context, never
floats, and preserves twelve fractional places for six-place rate × six-place
units. Result lines use `numeric(40,12)`. Net is earnings minus deductions;
employer contributions are shown separately. Settings, future rate versions,
source changes and ambient decimal precision cannot affect replay. Monetary
formatting does not imply a currency-specific settlement rounding policy.

Migration `20261001021001` is `:bilimbi_only`. Contributions, calculations,
result lines, final decisions and document references are append-only. Database
triggers validate run tenant/company ownership, require locked setup for results,
reject contributions/results after calculation, require independent decisions
and require approval before attaching documents. Company advisory locks
serialize facade intake, calculation and approval. The fresh migration test
checks the combined schema contract and actual database refusal behavior.

## Private payslips and reports

`Payroll.generate_document/5` generates a report for the approved run or a
payslip for an employee with a frozen result. `DocumentOwner` implements the
Base Artifacts Owner and PDF contracts. It re-reads approved frozen data before
rendering; arbitrary caller PDF contents are never trusted. The compact,
paginated PDF contains employee/item identifiers, exact rate calculations,
totals, currency and the replay digest. The renderer uses built-in fonts and
fetches no resources or external executables. No executable vendor bank format
is provided. The serializer implements the Base Artifacts PDF behaviour and is
expected to move into Base Artifacts when a second domain needs PDF rendering.

Base Artifacts owns bytes, reservations, integrity, retention and audit. Payroll
stores only provenance and the returned artifact UUID, never paths or duplicate
file storage. Configure private `artifacts.storage_root` and positive
`artifacts.retention_days` in `/system/settings` before generation. Missing
storage/retention refuses generation without affecting the approved calculation.
The adapter validates live Company scope and current payroll permissions on
every create/read/delete/purge. Payroll managers may run
`Artifacts.purge_expired(scope, company_id, Payroll.DocumentOwner)` and the Base
held-purge recovery APIs; Base's documented operator policy governs retries.

Every `/people/payroll/documents/:id?company_id=…` request calls Base read again;
the attachment uses `private, no-store` and `nosniff` headers. Expired, deleted,
corrupt, unapproved or unauthorized documents return no bytes. Document expiry
or physical purge does not remove financial result history. Download permissions
are payroll company review permissions; this slice does not expose employee
self-service payslips.

Payroll menu leaves remain hidden pending whole-area acceptance.
