# Leave

Module ID: `people/leave`. Leave types, entitlement policies, balances,
requests with approval, and year-end carry-forward.

This module owns fresh `people_leave_catalog_types`, `people_leave_policies`,
`people_leave_ledger_entries`, `people_leave_applications`,
`people_leave_application_dates`, `people_leave_request_events` and
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
  corrections are new entries. `grant_entitlements/3` gives every current
  workforce employee each active type's entitlement from the version in force
  on the first day of the leave year, once per employee, type and year, and
  records the policy version; it skips, and counts as `closed`, an employee and
  type whose year is already carried forward. `record_entry/4` writes `opening`
  and `adjustment` entries, idempotent by company, source and key; a conflicting
  replay is refused, and so are the module's own sources `policy`, `request`
  and `carry_forward`. Quantities are in the type's unit with two decimals.
  `balances/4` sums entries per type and also reports the quantity `pending`
  requests reserve and the `available` balance after that reservation.

## Authorization

Every write, and every read of other employees' requests, authorizes the
scope's signed-in actor for its own capability when it runs, through
`Bilimbi.People.Workforce.Authorization` at the facade, so pages, the
carry-forward worker and any other adapter share one boundary. Policy,
ledger, grant and carry-forward operations and the skip report need
`people.leave.policies.manage`; `pending_requests/2` and `decide_request/5`
need `people.leave.requests.approve`; `submit_request/3`, `cancel_request/3`,
`self_summary/3` and `self_requests/2` need `people.leave.self.view` and
resolve the account's current link to a working employee on every call,
proving it again under the employee's affiliation lock inside the write
transaction. A system scope, a grant revoked while a page stays open, and an
account unlinked from its employee are refused with `:unauthorized` or
`:not_linked`; the performer is the scope's actor, never an argument.

## Requests and approval

An employee requests leave for the Core Employee linked to their Core User,
only while that employee is current in the workforce seam.
`submit_request/3` takes a leave type, dates, a `day_part` and a client
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
balance and overlap checks cannot race. `decide_request/5` approves or
rejects a pending request. The requester and the request's own employee are
refused (`:self_approval`), as is an approver whose user cannot be resolved,
and a rejection needs a note. Approval rechecks the employee, the type and the
balance, then writes a `taken` ledger entry of the negative quantity with the
approver as actor. `cancel_request/3` lets the
employee cancel a pending request, or an approved one before its start date,
which writes a `cancelled` entry returning the quantity. Rejected and cancelled
requests release their slots. Each transition is an append-only row in
`people_leave_request_events` with its actor and note.

## Carry-forward

`carry_forward/3` closes one leave year after it has ended. For every active
type whose policy in force on the year's last day has a cap, each current
employee's closing balance up to the cap becomes a `carried_forward` entry on
the first day of the next year, and any excess becomes an `expired` entry on
the last day. A negative balance carries nothing.

Each processed employee and type gets one `carried_forward` entry, even of
zero, keyed by type, employee and year. That entry closes the year and every
earlier year for them: a repeated run changes nothing, grants skip them, and
new requests, approvals, cancellations and `record_entry/4` entries in those
years are refused with `:year_closed`, so no quantity is spent twice. Carried balances do not expire later in this slice.

Years close in order per employee and type, so no year is stranded. A run
skips an employee and type with pending requests in the year (`pending`), or
with an earlier year still open (`previous_year_open`): a year after their
last carried one with pending requests, or with ledger entries under a capped
policy. Earlier years without entries, such as before a later hire, do not
hold the run back, and uncapped years never carry; closing the year closes
them. The run returns a count per reason and replaces its year's rows in
`people_leave_carry_forward_skips`, each naming the leave year to resolve: the
year itself for a pending request, or the earliest earlier year not carried
forward yet. Closing an employee and type through a year clears their rows of
that year and earlier and the rows it resolves. `carry_forward_skipped/2`
reads the stored rows of every year, oldest first and at most 200, with the
total count, so the Policies page lists each year that still has skipped
employees after the queued jobs and notes when the list is cut short. Running the years again, oldest first,
once the cause is resolved carries them.

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
encashment and payroll handoff belong to later slices. `requested_type_ids/4`
returns the leave types with a pending or approved request overlapping a date
range, for Payroll's unmapped-source report.

The migration versions `20260930160101`, `20260930190101` and
`20260930200101` are
`:bilimbi_only` and must remain globally unique. The owned `SchemaContract`
describes the fresh tables, but the descriptor does not register it with
compatibility verification: that verifier also runs before pending
Bilimbi-only migrations, when these tables correctly do not exist. Before
deploying, follow the People-table inventory step in
`attendance/docs/README.md`.
