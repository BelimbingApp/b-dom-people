# Claims

Module ID: `people/claims`. Claim catalog, effective-dated claim policies,
assignments, employee claim requests, decisions, reimbursement, and hand-off.

## Ownership

This module owns nine fresh Bilimbi-only tables. The catalog uses
`people_claim_catalog_groups` and `people_claim_catalog_types`; effective policies,
assignments and requests use `people_claim_policy_versions`,
`people_claim_employee_enrolments` and `people_claim_submissions`. It also owns
the append-only request status history, assignment claim-type and employee
links, and hand-off batches. Call `Bilimbi.People.Claims` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit platform company ID; callers do
not query its schemas. Core Company validates the company, Core User links a
login actor to an employee, the People workforce seam decides who is a working
employee, and Core Employee's affiliation lock serializes each employee's
claim writes. A login actor is never treated as an employee by itself.

## Authorization

Every write, and every read of other employees' claims, authorizes its own
capability for the scope's signed-in actor at the moment it runs, through
`Bilimbi.People.Workforce.Authorization`; a system scope is refused with
`:unauthorized`. Catalog and policy writes need `people.claims.manage`;
decisions and the operator queue need `people.claims.approve`; paying,
hand-off batches and the CSV export need `people.claims.reimburse`;
self-service needs `people.claims.submit`. No function takes an actor or
actor ID: attribution comes from the scope's actor. A page's route grant is
proven at mount only, so a grant revoked while a page stays open refuses the
next event.

Self-service functions (`self_service_employee/2`, `self_open_claim_types/2`,
`self_requests/2`, `submit_request/3`, `withdraw_request/3`) act on the
employee the actor's account is linked to now. A write proves that link
again inside the transaction that holds the employee's affiliation lock, the
lock account replacement takes, so an account unlinked or relinked while a
page stays open cannot act on its former employee (`:not_linked`, or
`:not_found` for another employee's claim).

## Currencies and policies

Claim currencies are the company-scoped Base Setting
`people.claims.currencies`. Its default is empty: a new company accepts no
claim until an operator chooses its currencies. Codes are three uppercase
letters (ISO 4217 shape); the module ships no currency list or default.

A claim type belongs to one category and declares a receipt rule: `always`,
`never`, or `above_threshold`, and who may claim it: `all_employees` (every
working employee) or `assigned_only`. A policy gives one claim type an effective
period, a currency from the company's list, and optional per-claim, calendar
month, and calendar year limits. A threshold receipt rule needs the policy's
receipt threshold. Periods of one claim type never overlap; an open-ended
policy can be ended, but not before a live claim incurred under it. Submission
holds the effective policy row while it checks and records the claim, so ending
a policy waits for an in-flight claim and then sees it.

## Requests

`submit_request/3` records one claim for the working employee linked to the
scope's actor. It is checked
against the policy in effect on the expense date, which must not be in the
future in the company time zone. The claim currency must equal the policy
currency and still be allowed. Monthly and yearly limits count every live
claim of the same employee, type, and currency in that calendar period.
Refusals are explicit atoms, listed in the function documentation.

Duplicates:

- a receipt reference already on any live claim of the same employee in the
  company, whatever its type, is refused, comparing case-insensitively and
  ignoring extra spaces; a partial unique index enforces the same rule;
- a live claim with the same type, date, amount, and currency is refused as a
  possible duplicate unless the submitter confirms it, which is recorded.

`withdraw_request/3` withdraws the actor's own submitted claim. Withdrawn
and rejected claims keep their history, stop counting toward limits, and
release their receipt reference. An approval for less than the claimed amount
counts toward limits for the approved amount.

## Assignments

An assignment is a named group with an effective period, the claim types it
opens, and the employees it covers. An `assigned_only` claim type is offered
to an employee, and accepted on submission, only when an assignment in effect
on the expense date covers both. Otherwise submission is refused with
`:claim_type_not_assigned`. Members must belong to the company; whether an
employee is working is judged when a claim is submitted, not when assigned.

## Decisions, reimbursement, and hand-off

A submitted claim is decided by someone other than its claimant:

- `approve_request/4` approves in full, or for a lower `approved_amount` with
  a `decision_reason`;
- `reject_request/4` needs a `decision_reason`, which the employee sees;
- `reimburse_request/4` records payment of an approved claim with an optional
  `payment_reference`.

A login actor never decides or pays a claim it submitted or one of the
employee it is linked to (`:own_claim`). Each transition locks the request,
checks its status, and writes its history row in one transaction, so a claim
is decided or withdrawn once. Statuses are `submitted`, `approved`, `rejected`,
`reimbursed`, and `withdrawn`; database checks keep the decision and
reimbursement columns consistent with the status.

Hand-off is an auditable record, not a payroll or accounting integration.
`create_handoff_batch/3` takes every approved claim of one currency that is
not yet in a batch and records the batch (count, total, actor, time); claims
of different currencies never share a batch. `handoff_export/3` renders a
batch as CSV from stored facts with the claim's current status, and neutralizes
cells that a spreadsheet would read as a formula. `reimburse_batch/4` marks the
batch's still-approved claims reimbursed. Nothing here assumes a currency,
account code, or payment format; downstream posting belongs to Payroll or a
finance integration that reads the batch through this facade.
`requested_claim_type_ids/4` returns the claim types with a claim incurred in a
date range that is not withdrawn or rejected, for Payroll's unmapped-source
report.

## Pages and menu

- **People > My work > My claims** opens `/people/claims` under
  `people.claims.submit`. The signed-in actor's company is the company axis;
  an actor without a linked working employee sees an unavailable state. The
  page resolves that employee through the facade on every event and reload,
  never from a value cached at mount. It lists open claim types with their
  currency, limits, and receipt rule, submits claims, and withdraws submitted
  ones. It shows each claim's
  decision, approved amount, and reason. Assigned-only types appear only for
  assigned employees.
- **People > Settings > Claim policies** opens `/people/claims/setup` under
  `people.claims.manage`. Operators choose one company they may manage and edit
  its claim currencies, categories, claim types, assignments, and policies.
  Each section has an empty state.
- **People > Time and expenses > Claim operations** opens
  `/people/claims/operations` under `people.claims.approve`. Operators choose
  one company they may approve for and work five views: awaiting decision,
  approved, reimbursed, rejected, and hand-off batches. Approve, reject,
  reimburse, batch creation, and batch reimbursement each wait for
  confirmation. Paying, batching, and exporting also need
  `people.claims.reimburse`, checked again for the selected company; without
  it those controls are absent and the batches view says so. The CSV is a
  download link built on the page, so nothing is stored outside the batch.

## Schema

Migrations `20260930150101` (catalog, policies, requests) and `20260930170101`
(assignments, decisions, reimbursement, hand-off) are `:bilimbi_only` and must
remain globally unique. They create no rows and copy no source table names or
migration sequence.
Run `mix bilimbi.migrate` from a mounted Bilimbi root. The owned
`SchemaContract` describes the fresh tables, but the descriptor does not
register it with compatibility verification: that verifier also runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
