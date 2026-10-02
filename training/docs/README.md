# Training

Slices 6B, 6C and 6D own a company-scoped course catalog, delivery events, sessions,
confirmed attendance, corrections as history, private evidence, governed requests,
versioned plans and company budgets.
Authorized direct routes are `/people/training/courses`,
`/people/training/sessions`, and `/people/training/records`.
All Training menu leaves stay hidden until the whole area's acceptance passes.
There is no legacy migration inventory, source adoption or cutover workflow.
Effectiveness, passports and insights remain later slices.

## Public API and scope

`Bilimbi.People.Training` receives a validated `Bilimbi.Base.Tenancy.Scope` and
an explicit **platform company ID** on every persistent operation. The scope's
sealed actor supplies the author and impersonator; callers cannot supply them.
Anonymous/system actors are refused. Cross-company operations require Core
Company's tenant-wide company capability as well as the operation capability.
Cross-tenant records remain out of scope. Archived companies are unavailable.
Workforce reads use `Bilimbi.People.Workforce.ReadResult.require_current/1`;
stale/unavailable workforce results refuse writes and show a recovery message.

Catalog capabilities are `people.training.courses.view`,
`people.training.courses.manage`, `people.training.sessions.view`, and
`people.training.sessions.manage`; participation capabilities are listed under
[Participation and evidence](#participation-and-evidence). Manage does not
silently grant view.
Session managers can select active courses through `event_courses/2` without
receiving course-management permission.

The catalog API lists, creates, and updates courses. Operators edit names and
descriptions in place through the shared UI components. Codes are stable and
unique within a company. Operators supply all names and descriptions; no
courses, skills, providers, or countries are seeded. Deactivating a course
prevents new events and retains existing scheduled delivery.

`create_event/3` requires an active course in the same tenant/company.
`create_session/3` requires an event in that company. Both take an explicit
positive whole-number capacity; no capacity default is installed. A session's
capacity cannot exceed its event's capacity. Each session is a delivery of the
same event cohort, so capacities are not summed across sessions. This slice
does not enroll employees, reserve seats, or claim remaining availability;
those facts belong to participation. Events and sessions are create-only in
this slice, and authorship is recorded on each fact.

## Time and calendar contract

Session input requires `starts_local`, `ends_local` (ISO local wall clocks)
and an explicit IANA `time_zone`. `local_instant/2` uses Base DateTime's time
zone database, rejects unknown zones, and refuses DST gaps and overlaps rather
than guessing. End must be strictly after start. UTC instants and the delivery
zone are persisted. No server-local or country-specific zone is assumed.

`calendar/4` returns sessions overlapping a half-open UTC interval:
`starts_at < until` and `ends_at > from`. It includes sessions starting before
the selected window, orders by instant and ID, refuses windows exceeding 366
days, and returns at most 500 rows. The page reports that bound when reached.
The UI selects a month and list/calendar mode through URL filters. Calendar
days use the selected company's operator-managed Base DateTime zone;
`day_start/2` bounds each month at the first instant of its local day, so a
DST gap or overlap at local midnight never blanks the page. Multiday sessions
appear on each intersected date. List timestamps use the reader's saved clock through the shared `datetime` component and separately
show the delivery zone. A session form starts with the company zone, which
an operator can change for that delivery. Company timezone remains managed
through the existing Core Company UI and Base Settings.

## Fresh schema and deployment

Each migration is declared `:bilimbi_only` with a globally unique version in
`bilimbi.module.exs`. Training owns its catalog, participation and governance relations.
Composite foreign keys enforce event/course and session/event tenant/company
identity. Checks enforce positive capacity and ordered instants. Database
triggers enforce session/event capacity and reject unknown stored time zones.
No sibling-private tables are read. No Core or Skills schema is duplicated.

Run Mix from the Bilimbi umbrella root. Before applying the first Training
migration to an existing deployment, inventory the two target environments
read-only for existing People/Training table existence and row counts. The
owner reports no People data to preserve; the disposable validation database
only proves fresh creation and does not certify an existing deployment. Stop
that deployment if unexpected live rows are found and obtain a migration
decision. These migrations neither adopt nor delete source data.

The contract stays unregistered because pre-migration compatibility checking
must not demand pending fresh tables. After `mix bilimbi.migrate`, verify it:

```elixir
Bilimbi.Base.Database.SchemaVerifier.verify(
  Bilimbi.Base.Repo,
  Bilimbi.People.Training.SchemaContract.tables()
)
```

Focused unit and real-host tests are under `training/test` and
`training/web_test`; Web discovers the latter through its test-helper bridge.

## Participation and evidence

`Bilimbi.People.Training.Participation.record/3` takes an explicit company,
session, current workforce employee, attendance status (`confirmed` or
`absent`), reason and company-unique `import_key`. The key is a durable
operational import identity, unrelated to migration-source inventory.
Replaying an identical key and payload returns the original fact, including
its actor and revision. Changing the payload refuses with `:import_conflict`;
a correction uses a new key and reason and appends the next revision.
Importing a batch means calling this seam for each row; retrying a partial
batch uses the same keys. No history is overwritten.

Current attendance is the last revision for each session/employee. Confirmed
attendance occupies a session place; an absent correction releases it. The
session lock serializes writers; migrated database triggers also enforce
capacity and consecutive revisions and prohibit fact/evidence updates and
deletions. Lowering capacity below confirmed attendance is refused. Employee
IDs are workforce subject identity; the sealed login actor supplies authorship
and impersonation, never an employee ID supplied as an actor.

The records page shows the most recent 500 sessions and all revisions for the
selected session. Evidence attaches to a particular immutable revision and
does not silently move when attendance is corrected.
`history/3`, `sessions/2`, and `evidence/3` require
`people.training.records.view`. `record/3` and `employees/2` require
`people.training.records.manage`. Uploads require
`people.training.evidence.manage`; retention requires
`people.training.retention.manage`. None grants another capability.
Permissions and company/workforce status are rechecked on every operation,
including requests from a page opened before permission revocation.

`attach/4` accepts PDF bytes with a PDF header, checks the scoped fact, then
calls `Bilimbi.Base.Artifacts.put/6` outside any outer Repo transaction.
The header is a format gate, not a full PDF safety scanner. Base enforces its
operator-configured maximum size. Training stores only the document ID and
provenance; it never stores bytes, paths, reusable access tokens or public URLs.
If linking fails, Base deletion is attempted; an interrupted unlinked document
still expires through Base's owner-scoped retention. The authenticated download
route calls Base `read/4` on every request and sends an attachment with
`private, no-store` and `nosniff` headers.

Use the authoritative [Base Artifacts integration guide](https://github.com/BelimbingApp/bilimbi/blob/9aa523905db2c70865fa3e4347747900370acb42/apps/base/artifacts/README.md)
for private storage provisioning, PDF contracts and operator settings.
An operator configures `artifacts.storage_root`, `artifacts.retention_days`,
maximum bytes and purge retry/hold settings at `/system/settings`.
Unset retention or storage refuses uploads. Expiry is captured at upload;
changing retention affects new documents. Expired documents refuse reads before
cleanup. Training keeps the historical reference after bytes are purged.

The records page exposes a bounded, explicit **Purge expired evidence** action
for retention operators and lists Base purge holds with retry actions.
`purge/2`, `purge_holds/2` and `retry_purge/3` are the matching API seams.
The current slice requires an authenticated user for maintenance and installs
no automatic schedule or system principal. Base records read/delete/purge
audits and handles retries, tombstones and held documents; Training does not
implement a second retention worker or file store.

## Learning requests, plans and budgets (slice 6D)

This slice adds direct authorized routes while the new menu leaves remain
hidden pending whole-area rollout acceptance. Task tabs are capability filtered:

| Route | Task and entry capability |
| --- | --- |
| `/people/training/my` | My learning / requests; `people.training.requests.submit` |
| `/people/training/team` | Direct-report requests; `people.training.requests.recommend` |
| `/people/training/plans` | Accountable team plans; `people.training.plans.submit` |
| `/people/training/requests` | HR request register and reviews; `people.training.requests.view` |
| `/people/training/plan-reviews` | HR plan reviews; `people.training.plans.view` |
| `/people/training/budgets` | Learning policy and budgets; `people.training.budgets.view` |

View capabilities do not imply decision rights. Operators grant HR review,
request approval, plan approval and budget management independently. No roles
are automatically granted this authority. Team recommendation requires both its
capability and a current Workforce reporting line. Plan authors must be current
working employees with direct reports. Login actors, employee subjects and
platform companies stay distinct; employee IDs are resolved through Workforce,
not read from another module's tables.

`create_learning_request/3` derives the employee from the authenticated user's
Core User link. It accepts a learning need, objective, expected result, proposed
date, exact estimated cost and explicit currency, plus an optional active course
in the same company. A request covers one employee. Client-supplied employee,
author, status and approval facts are discarded. The flow is draft → pending
HOD → pending HR → pending approval → approved. The linked employee submits
and cancels their own pending request; their direct supervisor recommends or
rejects it; independent HR reviewers and approvers decide their stages with
`requests.review` and `requests.approve`. Every transition needs a reason.
Rejection and cancellation are terminal; a corrected need is a new request.
Both authored and subject self-approval are refused even with a decision grant.
The public read `learning_requests/3` accepts `:self`, `:team` or `:hr` and checks
the corresponding capability. `learning_histories/5` returns decision history
for a page of record IDs under the same audience rule and omits IDs outside it.
A request the employee never submitted, still in draft or cancelled from draft,
stays private to them: the `:team` and `:hr` audiences omit it from both reads.

`create_learning_plan/4` takes period, objectives, reason and a nonempty list of
items. Each item records its need, expected result, target cohort, responsible
owner, timing and evaluation approach. An optional approved request link must
belong to the author's current direct-report team. Plan content and items stay
immutable. The accountable author submits a draft; independent HR approves or
rejects the submitted scope with `people.training.plans.approve`.
`amend_learning_plan/5` creates a new reasoned version of an approved plan.
The prior approved scope remains effective until HR approves the amendment,
then becomes superseded with another decision row. A competing amendment cannot
supersede an already superseded prior version. `learning_plans/3` returns the
actor's team plans or the capability-protected HR register. A plan or amendment
stays private to its manager until submitted: the HR register and
`learning_histories/5` omit drafts and plans cancelled from draft. Plans record
learning scope, not financial commitments; request approval reserves the money once.
They never enroll employees, alter participation, cancel sessions or infer
training completion. Slice 6C can consume these schema-free APIs later.

Company currencies live in the Base Setting `people.training.currencies`, with
an empty default. The budget page supplies its operator editor; only
`people.training.budgets.manage` can save currencies or allocate a policy.
`create_budget_policy/3` records immutable, reasoned allocations with explicit
currency and inclusive effective dates. Periods for the same currency may not
overlap. A new effective period is a new policy, never a rewrite of an earlier
allocation. `supersede_budget_policy/4` corrects a mistaken allocation: the
operator gives a reason and the corrected period and amount, and a new row in the
same currency records `supersedes_id`. The original row stays unchanged and is
listed as superseded; overlap checks, approvals and committed totals use only
current policies. A correction is refused when approved commitments in its
period exceed the new amount, or when approved requests inside the replaced
policy's period would fall outside the corrected period. Requests and
allocations require an enabled currency. Approval
requires a policy covering the request's proposed date, snapshots its ID and
the approved amount, and refuses spending above that allocation. Missing
policy is unavailable, not an unlimited budget. There is no implicit currency
conversion or budget override. Amounts use decimal arithmetic with four places;
excess precision is refused rather than silently rounded. The budget page shows
allocated, committed and remaining amounts per currency and period. Pending
requests do not spend money. Removing an enabled currency refuses new approvals
in that currency while preserving already approved financial facts.

Policy creation and request/plan decisions serialize through one transaction
lock per tenant/company. PostgreSQL also rejects overlapping policy inserts,
budget violations, scope-mismatched references, edits/deletes of allocations,
plan items and decision rows, and changes to terminal request facts. Every
history row records the sealed actor and optional impersonator. The shared
confirmation dialog precedes a decision; hidden controls still have a first
write-event deny clause and the API rechecks live capabilities and workforce.

The new migration `20261001060401` is fresh `:bilimbi_only` schema with no seeds,
legacy imports, migration inventory or participation dependency. The fresh
schema contract above includes these six relations. Verification used newly
created disposable development and test databases; target deployment inventory
is still the read-only operator prerequisite described above.
