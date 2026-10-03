# Employee workspace

Module ID: `people/employee_workspace`.

The workbench is at `/people/employees`, with detail at
`/people/employees/:id`. The menu contributes **People > Team > Employees**
only because the route, `people.employees.view` capability, company selection,
and empty state are implemented. The signed-in actor's company is the explicit
platform company axis. No tenant-wide employee list is implied by the route.

Core Employee owns employee identity and employment facts. This module calls
its public API and stores only People-specific work profile, portal eligibility,
profile-change request history, and actor-owned saved view facts. Portal
eligibility neither creates a login account nor grants a role. An approved
change request records the decision; an operator must apply an approved master
change through Core Employee's own workflow.

The public facade requires `Bilimbi.Base.Tenancy.Scope` and explicit company
and employee IDs. Writes lock live Company and Employee affiliation through
Core Employee's public contract before writing People tables. Missing or
cross-company employees are refused. Pages also use Core Company's actor-aware
target authorization and separate read, manage, and review capabilities.

Migration `20260930120101` is fresh `:bilimbi_only` schema. It creates no
employee rows and copies no source table names or migration sequence. Work
profiles are stored in `people_employee_workspace_profiles`. Run
`mix bilimbi.migrate` from a mounted Bilimbi root.
`Bilimbi.People.EmployeeWorkspace.SchemaContract` stays unregistered;
`test/schema_contract_test.exs` checks it against a freshly migrated database
with `Bilimbi.Base.Database.SchemaVerifier.verify/2`.
