# Leave

Module ID: `people/leave`. Leave types, entitlement policies, balances,
requests with approval, and year-end carry-forward.

This module owns fresh `people_leave_types`, `people_leave_policies`,
`people_leave_ledger_entries`, `people_leave_requests`,
`people_leave_request_days`, `people_leave_request_events` and
`people_leave_carry_forward_skips` tables. Call
`Bilimbi.People.Leave` with a validated `Bilimbi.Base.Tenancy.Scope` and
explicit company ID; company and employee identity come from
`people/workforce` and must be current. Missing, sibling-company and
cross-tenant records are indistinguishable.

- **Leave year.** The company-scoped Base Setting
  `people.leave.year_start_month` (default January) sets when each leave year
  starts. A leave year is labelled by the calendar year it starts in. It cannot
  change once the company has ledger entries, because each entry stores its
  leave year.
- **Types.** A company's types have a unique lowercase code, a name, a unit
  (`day` or `hour`), a paid flag and whether requests need an available
  balance (`balance_required`, default true). Archived types take no new
  policy versions, grants, requests or entries, but keep their history and
  balances.
- **Policy versions.** Each type has effective-dated entitlement versions. A
  new version must start after the latest one, which it closes on the previous
  day, and after every entitlement already granted for that type. Versions are
  never edited. An optional carry-forward cap is the most of a closing balance
  carried into the next leave year; without one the type does not carry
  forward.
- **Ledger.** Entries are append-only, enforced by a database trigger;
  corrections are new entries. `grant_entitlements/4` gives every current
  workforce employee each active type's entitlement from the version in force
  on the first day of the leave year, once per employee, type and year, and
  records the policy version; it skips, and counts as `closed`, an employee and
  type whose year is already carried forward. `record_entry/4` writes `opening`
  and `adjustment` entries, idempotent by company, source and key; a conflicting
  replay is refused, and so are the module's own sources `policy`, `request`
  and `carry_forward`. Quantities are in the type's unit with two decimals.
  `balances/4` sums entries per type and also reports the quantity `pending`
  requests reserve and the `available` balance after that reservation.

## Requests and approval

An employee requests leave for the Core Employee linked to their Core User,
only while that employee is current in the workforce seam.
`submit_request/4` takes a leave type, dates, a `day_part` and a client
`request_key`:

- `full` counts each date in the range; `am` and `pm` are half of one date;
  `hours` gives a number of hours (up to 24) on one date and is the only form
  an hour-unit type accepts.
- Only the company's working weekdays are counted, and never a date that is a
  `people/reference_data` calendar exception. The company-scoped settings
  `people.leave.working_weekdays` (ISO weekday numbers, default Monday to
  Friday) and `people.leave.request_backdate_days` (default 30, 0 to 366)
  hold these rules. A request with no counted date is refused.
- A request stays within one leave year and may not start further back than
  the backdating limit. There is no forward limit.
- Each counted date holds its morning and afternoon slots while the request is
  pending or approved. Two partial unique indexes on active slots make
  overlapping live requests for one employee impossible; the two halves of a
  date may be separate requests.
- When the type requires a balance, the ledger balance of that year less other
  pending requests must cover the quantity. Pending requests reserve their
  quantity until decided.
- A replay with the same `request_key` returns the existing request; a
  different request under the key is refused.

Every write for one employee takes Core Employee's affiliation lock, so
balance and overlap checks cannot race. `decide_request/6` approves or
rejects a pending request. The requester and the request's own employee are
refused (`:self_approval`), as is an approver whose user cannot be resolved,
and a rejection needs a note. Approval rechecks the employee, the type and the
balance, then writes a `taken` ledger entry of the negative quantity with the
approver as actor. `cancel_request/4` lets the
employee cancel a pending request, or an approved one before its start date,
which writes a `cancelled` entry returning the quantity. Rejected and cancelled
requests release their slots. Each transition is an append-only row in
`people_leave_request_events` with its actor and note.

## Carry-forward

`carry_forward/4` closes one leave year after it has ended. For every active
type whose policy in force on the year's last day has a cap, each current
employee's closing balance up to the cap becomes a `carried_forward` entry on
the first day of the next year, and any excess becomes an `expired` entry on
the last day. A negative balance carries nothing.

Each processed employee and type gets one `carried_forward` entry, even of
zero, keyed by type, employee and year. That entry closes the year for them:
a repeated run changes nothing, and new requests, approvals, cancellations and
`record_entry/4` entries in that year are refused with `:year_closed`, so no
quantity is spent twice. Carried balances do not expire later in this slice.

Years close in order per employee and type, so no year is stranded. A run
skips an employee and type with pending requests in the year (`pending`), with
a previous year still open (`previous_year_open`: a capped type with ledger
entries or pending requests in that year and no carry-forward), or whose next
year is already closed while this year has ledger entries
(`next_year_closed`). An employee without entries in the year, such as one
hired later, is not held back: the run closes their year with a zero entry.
The run returns a count per reason and replaces its year's rows in
`people_leave_carry_forward_skips`; `carry_forward_skipped/3` reads that
report, so the Policies page shows the latest run's skipped employees, types
and reasons after the queued job. Running the year again once the cause is
resolved carries them.

`enqueue_carry_forward/3` queues `Bilimbi.People.Leave.CarryForwardWorker`
(worker ID `people-leave/carry-forward`) through Base Queue as the signed-in
operator. When it runs, the operator's company reach and
`people.leave.policies.manage` are checked again.

## Pages

- `/people/leave/my` (**My leave** under People > My work, capability
  `people.leave.self.view`) shows the current leave year's balances with
  pending and available quantities, a request form, the employee's own
  requests with cancellation, and history, using the company time zone for
  today.
- `/people/leave/requests` (**Leave approvals** under People > Team,
  capability `people.leave.requests.approve`) lists an authorized active
  company's pending requests with employee names and approves or rejects them.
- `/people/leave/policies` (**Leave policies** under People > Settings,
  capability `people.leave.policies.manage`) edits a company's leave year,
  request rules, types and policy versions, runs grants, and queues
  carry-forward.

All pages have unavailable and empty states. New installations have no types,
policies, entries or requests, and no country, statutory or customer
defaults. Service-length bands wait for a workforce hire-date contract;
encashment and payroll handoff belong to later slices.

The migration versions `20260930160101`, `20260930190101` and
`20260930200101` are
`:bilimbi_only` and must remain globally unique. The owned `SchemaContract`
describes the fresh tables, but the descriptor does not register it with
compatibility verification: that verifier also runs before pending
Bilimbi-only migrations, when these tables correctly do not exist. Before
deploying, follow the People-table inventory step in
`attendance/docs/README.md`.
