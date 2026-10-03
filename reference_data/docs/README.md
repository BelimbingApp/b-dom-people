# ReferenceData

Module ID: `people/reference_data`. People reference entries and calendar exceptions.

This module owns three fresh Bilimbi-only tables:
`people_reference_data_entries`, `people_reference_data_aliases`, and
`people_reference_data_calendar_overrides`. Call `Bilimbi.People.ReferenceData` with a validated
`Bilimbi.Base.Tenancy.Scope` and explicit company ID. The facade checks that
company through Core Company before reading or writing; callers do not query
its schemas. An alias label is unique per reference kind within a company.
New installations have no reference values or calendar exceptions.

The operator route `/people/companies/:company_id/references` requires
`people.references.manage` and Core Company's target reach: the actor's own
company, or a sibling company with tenant-wide company authority. It shows an
empty state for a company without records. People > Settings > People
references opens `/people/references` with an authorized company chooser and a
meaningful empty state when no company is available. The explicit company route remains available. Every selection and
write event rechecks current capability and company reach.

Authorization is per operation, inside the facade: `create_entry/3`,
`add_alias/4` and `create_calendar_exception/3` evaluate
`people.references.manage` for the scope's sealed actor and the target
company through `Bilimbi.People.Workforce.Authorization.authorize/3` when
they run, and return `{:error, :unauthorized}` otherwise. The page's
`can_manage?` assign only decides which controls render; a grant revoked
while the page stays connected refuses the next write. Reads stay
capability-free company configuration so Leave can consume calendar
exceptions. Tests sign an operator in with
`Bilimbi.People.Workforce.AuthorizationFixtures`.

The migration version `20260930100101` is `:bilimbi_only` and must remain
globally unique. No Belimbing table or data adoption is involved.
The owned `SchemaContract` describes the fresh tables, but the descriptor does
not register it with compatibility verification: that verifier also runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.

`test/schema_contract_test.exs` runs the original migration in a fresh database
and verifies the owned contract with
`Bilimbi.Base.Database.SchemaVerifier.verify/2`.
