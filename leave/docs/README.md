# Leave

Module ID: `people/leave`. Leave types, entitlement policies and balances.

This slice owns fresh `people_leave_types`, `people_leave_policies` and
`people_leave_ledger_entries` tables. Call `Bilimbi.People.Leave` with a
validated `Bilimbi.Base.Tenancy.Scope` and explicit company ID; company and
employee identity come from `people/workforce` and must be current. Missing,
sibling-company and cross-tenant records are indistinguishable.

- **Leave year.** The company-scoped Base Setting
  `people.leave.year_start_month` (default January) sets when each leave year
  starts. A leave year is labelled by the calendar year it starts in. It cannot
  change once the company has ledger entries, because each entry stores its
  leave year.
- **Types.** A company's types have a unique lowercase code, a name, a unit
  (`day` or `hour`) and a paid flag. Archived types take no new policy
  versions, grants or entries, but keep their history and balances.
- **Policy versions.** Each type has effective-dated entitlement versions. A
  new version must start after the latest one, which it closes on the previous
  day, and after every entitlement already granted for that type. Versions are
  never edited.
- **Ledger.** Entries are append-only, enforced by a database trigger;
  corrections are new entries. `grant_entitlements/4` gives every current
  workforce employee each active type's entitlement from the version in force
  on the first day of the leave year, once per employee, type and year, and
  records the policy version. `record_entry/4` writes `opening` and
  `adjustment` entries, idempotent by company, source and key; a conflicting
  replay is refused. Quantities are in the type's unit with two decimals.
  `balances/4` sums entries per type.

The operator page `/people/leave/policies` (**Leave policies** under People >
Settings, capability `people.leave.policies.manage`) selects an authorized
active company and edits its leave year, types and policy versions, and runs
grants. `/people/leave/my` (**My leave** under People > My work, capability
`people.leave.self.view`) resolves the logged-in Core User to a Core Employee
and shows the current leave year's balances and history, using the company
time zone for today. Both pages have unavailable and empty states.

New installations have no types, policies or entries, and no country, statutory
or customer defaults. Requests, approvals, taken days, carry-forward and
expiry belong to the leave request slice. Service-length bands wait for a
workforce hire-date contract.

The migration version `20260930160101` is `:bilimbi_only` and must remain
globally unique. The owned `SchemaContract` describes the fresh tables, but the
descriptor does not register it with compatibility verification: that verifier
also runs before pending Bilimbi-only migrations, when these tables correctly
do not exist. Before deploying, follow the People-table inventory step in
`attendance/docs/README.md`.
