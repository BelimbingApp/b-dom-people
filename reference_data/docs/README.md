# ReferenceData

Module ID: `people/reference_data`. People reference entries and calendar exceptions.

This module owns three fresh Bilimbi-only tables: reference entries, aliases,
and calendar exceptions. Call `Bilimbi.People.ReferenceData` with a validated
`Bilimbi.Base.Tenancy.Scope` and explicit company ID. The facade checks that
company through Core Company before reading or writing; callers do not query
its schemas. An alias label is unique per reference kind within a company.
New installations have no reference values or calendar exceptions.

The operator route `/people/companies/:company_id/references` requires
`people.references.manage` and Core Company's target reach: the actor's own
company, or a sibling company with tenant-wide company authority. It shows an
empty state for a company without records. The menu leaf is hidden because
navigation has no selected company ID to build this explicit route.

The migration version `20260930100101` is `:bilimbi_only` and must remain
globally unique. No Belimbing table or data adoption is involved.
The owned `SchemaContract` describes the fresh tables, but the descriptor does
not register it with compatibility verification: that verifier also runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
