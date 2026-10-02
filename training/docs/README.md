# Training

Slices 6B through 6F own a company-scoped course catalog, delivery events, sessions,
confirmed attendance, corrections as history, private evidence, governed requests,
versioned plans, company budgets, employee evaluations and HOD effectiveness reviews.
Authorized direct routes are `/people/training/courses`,
`/people/training/sessions`, and `/people/training/records`.
Training now contributes the eight task-based menu leaves below, each filtered by its route capability.
There is no legacy migration inventory, source adoption or cutover workflow.
My and Team passports share Training records rather than adding separate passport roots.

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

## Evaluation and effectiveness (slice 6E)

Employees answer their own evaluations in the **My evaluations** section of
My learning (`/people/training/my`), beside their learning requests. That
section requires the own-learning entry `people.training.requests.submit` and
`people.training.evaluation.submit`; it does not require Effectiveness access.

`/people/training/effectiveness` is one authorized destination with HOD Review,
the frozen HR Summary, policy publication and maintenance sections filtered by
capability. It has one reserved **Effectiveness** menu entry under Development,
returned by `Contributions.effectiveness_menu/0`; the runtime contribution
remains empty until the whole Training area's acceptance passes. No separate
HOD and HR menu roots are introduced.

Grant `people.training.effectiveness.view` for Effectiveness entry, then
independently grant the tasks the actor needs:

| Capability suffix (after `people.training.`) | Task |
| --- | --- |
| `evaluation.submit` | With `requests.submit`, read and answer the linked employee's own evaluations under My learning |
| `effectiveness.answer` | Read and answer effectiveness reviews for current direct reports |
| `effectiveness.summary.view` | Read the frozen, privacy-protected company HR summaries |
| `evaluation.policy.manage` | Read and publish effective-dated criteria versions; configure evaluation settings |
| `evaluation.reminders.manage` | Prepare completed-session reviews, refresh the due-reminder worklist and freeze closed reporting periods |

Task rights do not imply one another. An HOD must have a current working
employee link and a current Workforce reporting line to the subject. HR
summary access exposes no individual answers, reasons, names or employee IDs.
All reads and writes recheck tenant, explicit platform company, active company
and live capability. Workforce identity is consumed only through its public
API and `ReadResult.require_current/1`. Lost links and reporting lines refuse
answers. A company's scope is never inferred from an employee or review ID.
The LiveView also refuses forged write events before processing them.

An operator with `people.training.evaluation.policy.manage` edits these
company-scoped Base Settings in the evaluation settings form on Effectiveness
(`put_evaluation_settings/3`), which validates and saves all six together.
Saved company values are the governed data. All except the reporting period
start unset, so publication and freezing fail closed until an operator saves.
For any unset field the form proposes an editable starting value: evaluation
due 7 days, checkpoints 30 and 90 days, reminder lead 3 days, disclosure
minimum 5, a 3-month calendar quarter and 14 answer grace days. These
proposals are not saved, captured or used until the operator submits the
form; there are no fallback criterion names.

| Setting under `people.training.evaluation.` | Meaning |
| --- | --- |
| `evaluation_days` | Evaluation deadline after the session's local completion day |
| `checkpoints` | A distinct list of positive day offsets for effectiveness deadlines |
| `reminder_days` | Days before a deadline when the worklist reminder becomes available |
| `minimum_cohort` | At least two distinct employees; disclosure also requires this many distinct employees with known scores |
| `report_months` | Fixed reporting period length in months; it must divide 12. Defaults to 3, a calendar quarter. A change applies from the day after the last frozen period |
| `report_grace_days` | Days after a period ends during which late answers still count before it freezes |

`publish_evaluation_policy/3` takes inclusive effective dates, separate employee
and HOD criterion lists and a publication reason. Each criterion is governed
data with `code`, `label`, `minimum` and `maximum` integer score bounds.
Publication appends a company version, refuses overlapping periods and
captures the configured due offsets and reminder lead. Changing Settings does
not alter an existing policy or an existing review. Criteria and deadlines
are permanent; publish the next effective period to introduce changed criteria.
`evaluation_policies/2` returns the history. Persisted criterion lists are
JSON objects under `items`, and checkpoints under `days`; callers submit lists
through the facade and receive schema-free maps.

`prepare_evaluation_reviews/4` takes a session ID and UTC clock instant. It
requires the session to have ended, a policy covering the session's completion
date in its own IANA time zone, and a current Workforce read. Latest confirmed
attendance of each current employee produces one employee evaluation and one
HOD review per checkpoint. Attendees who are no longer current employees are
skipped and counted in the result's explicit `unknown` outcome, so one leaver
never blocks the rest of the session; the result is
`%{reviews: reviews, unknown: count}`.
The review captures the attendance fact and policy version. Repeat runs return
the same obligations; a confirmed attendance correction cannot duplicate them.
An absent correction removes an obligation from current reads, reminders and
summaries and refuses an answer, while retaining historical facts. The
operator runs this explicitly; no automatic schedule or enrollment is implied.

`evaluation_reviews/3` accepts `"evaluation"` or `"effectiveness"` and applies
self or current direct-report scope. `answer_evaluation/5` receives a review ID,
criterion values and evidence/explanation. Every criterion key must be present;
a value is an integer within the captured criterion's bounds or explicit `nil`
for unknown. Unknown does not mean zero. The sealed login actor and optional
impersonator provide attribution. One answer per review is permanent and the
UI confirms submission. Answers do not amend course, request, plan, attendance,
skill or performance data.

`evaluation_reminders/3` takes the company's reporting day and creates a
reminder once when `today >= due_on - reminder_days`, including the due day
and overdue tasks. Answered and currently absent obligations are skipped.
The recipient is the current employee for an evaluation or current HOD for an
effectiveness review. Missing subjects or supervisors increment the run's
explicit `unknown` outcome rather than inventing a recipient. My evaluations
and the HOD Review list show available reminders to the current actor. This is
a durable worklist, not an email-delivery log; this slice sends no mail and installs no system
principal or unattended worker. A changed reporting line changes who can see
and answer the obligation, and never grants access through the historical
reminder recipient.

`freeze_effectiveness_summaries/3` takes the company's reporting day. Frozen
periods form one contiguous chain with no gap or overlap. The first period is
the calendar-aligned period containing the earliest effectiveness deadline;
each next period starts the day after the last frozen period end and runs for
the currently configured length. A changed length therefore takes effect from
that date: after a frozen January–March quarter, a change to 6 months freezes
April–September next. `effectiveness_period_start/2` returns that date for
policy managers, and the Effectiveness page shows it beside the evaluation
settings form. A period is computed only after it ends and its answer grace
window has passed, including empty periods, which freeze as suppressed. It is
then stored as a permanent snapshot in `people_training_effectiveness_summaries`.
A frozen period never recomputes: later answers, late-prepared reviews and
attendance corrections cannot change it. This keeps an HR reader from
differencing two readings to recover one answer. Each snapshot keeps separate
policy-version/checkpoint groups so different criterion versions are never
averaged together, and records the disclosure minimum it applied. Both a
cohort and its known-score population must meet that minimum; below it,
scores and counts remain suppressed in the snapshot. Unknown scores are
excluded from the mean, not imputed; a criterion with insufficient known data
has no count or mean. Means are stored rounded to two decimals. Stale or
unavailable workforce refuses the freeze with no snapshot.

`effectiveness_summary/2` only reads the frozen snapshots, newest period first;
page loads never compute scores. The UI offers no arbitrary employee/cohort
drill, complement totals or individual export.

Migration `20261002060501` declares `:bilimbi_only` and adds five fresh relations
with composite tenant/company references. PostgreSQL enforces policy versions,
nonoverlapping periods, criterion bounds, review deadlines and uniqueness,
and permanent policy/review/answer/reminder/summary history. The schema contract is
included in `Training.SchemaContract.tables/0` and stays unregistered until
fresh migration, as described above. Focused real-host tests cover due-day and
repeat reminder behavior, unknown answers and recipients, skipped leavers,
small cohorts, frozen summaries that later answers cannot change,
role/company/tenant refusal, lost reporting lines, attendance corrections,
publication and answer history, forged events and the fresh schema verifier.
The target deployment inventory prerequisite remains unchanged: disposable
databases prove fresh creation, not the contents of either deployment.


## Passports, insights and completed navigation

`Training.passport/5` reads My (`:self`) or current direct-report Team (`:team`)
records. The login actor's Core User employee link supplies identity; callers
cannot substitute an employee for My access. Both audiences require the actor's
own platform company and a live company in the authenticated tenant. They never
inherit tenant-wide HR record access. Capabilities are
`people.training.passport.my.view`, `people.training.passport.team.view`, and
`people.training.passport.generate`. Generate also requires the selected audience
view capability. A passport lists the latest attendance revision per session,
including corrected absences, with evidence from that revision. Evidence on an
older revision remains privately accessible to its employee/current manager.
A changed reporting line or revoked capability refuses subsequent downloads.

`generate_passport/4` uses `Base.Artifacts.generate_pdf/5` and
`Base.Artifacts.PDF.Renderer.render/1`. Base stores the frozen generated bytes,
opaque employee/audience subject, actor and impersonator attribution, hash and
expiry; no duplicate Training document table or PDF serializer is needed.
Base Operator Settings controls storage, maximum bytes and retention. Existing
Training records retention controls now purge both evidence and passports,
including held-document retries. Expiry refuses reads even before physical purge.
Documents over 1,000 session records refuse rather than silently truncating.
The shared renderer supports printable ASCII and Latin-1 body text; unsupported
scripts fail explicitly. No external resource or executable is used.

Native workforce reads are current. Passport readers retain the actual
`Workforce.ReadResult`: a stale My value displays its last-confirmed time and
refuses document generation. Team membership and publication require current
workforce, so stale/unavailable Team data refuses access rather than trusting an
old reporting line. Unavailable employee linkage has a recovery message.
No local age heuristic or fallback freshness status replaces Workforce authority.

`learning_insights/3` groups latest attendance by course in an explicit inclusive
UTC completion-date window of at most 366 days. Counts distinguish attendance
from distinct employees. Company evaluation `minimum_cohort`, managed on
Effectiveness and Base Operator Settings, suppresses all counts in small groups;
an unset threshold refuses the report. Evaluation scores are never recomputed
for arbitrary windows: the one Effectiveness page retains frozen, suppressed
period summaries. `learning_insight_drill/4` additionally requires company-wide
`people.training.records.view`; aggregate-only viewers cannot drill. Summary,
drill and passport rows are paged in SQL with a maximum 300 rows per response.
Date/company/page/page-size selection lives in the URL. The UI clearly separates
these operational attendance facts from effectiveness scores.

The completed Training leaves match the port plan:

| People group | Leaf | Destination |
| --- | --- | --- |
| My work | My learning | Requests, evaluations, My passport and evidence task links |
| Development | Courses | Governed course catalog |
| Development | Sessions & calendar | Events and session list/calendar |
| Development | Learning requests & reviews | Request register, team requests/plans and plan reviews by capability |
| Development | Training records | Attendance/evidence and My/Team passport tabs by capability |
| Development | Effectiveness | One page with authorized Review/Summary and evaluation policy tasks |
| Reports | Learning insights | Bounded course counts and authorized attendance drills |
| Settings | Learning policy and budgets | Company currencies and effective budgets, with evaluation-policy task link |

The My/Team passport routes are `/people/training/records/my` and
`/people/training/records/team`; insights is `/people/training/insights`.
There are no separate Team Passports/My Training Passport roots, migration
sources, or duplicate Effectiveness entries. Existing task-specific capabilities
remain explicit grants; granting a menu route does not grant its linked tasks.
Unfinished unrelated areas remain hidden.

My learning uses `people.training.learning.view`; the Training records landing
page uses `people.training.records.workspace.view`. These grant the task shell
only: request, evaluation, My/Team passport and company attendance capabilities
remain separately checked. Grant the shell with the relevant task capability so
passport-only learners and team managers have a menu destination without receiving
company-wide record access.

### Slice 6F validation

Validated on Bilimbi `cd98044ea278305380e0f7969cf9f347c42ec6fe` with
Factory main `48f636f886cb7371a82f619efeb7363056ddcc1e`. Mounted strict
compilation and full `mix precommit` passed, including the prior Training
slices and the new My/Team ownership, private PDF, retention, correction,
pagination, KPI and menu tests. A fresh complete migration passed and both
Training schema contracts verified against it. Full absent `mix precommit`,
explicit Training route/capability absence and unmounted migration validation
also passed. The repository migration-version and composition graph/mandate
checks passed. No additional Training migration or compatibility table is
introduced by this slice.

Live browser validation was skipped after the permitted fresh-page attempt
failed with “No page is currently selected”; real-host LiveView and controller
tests cover the new pages, task shells and document responses.

A second attempt used a fresh named browser session and an isolated host on
port 4017 with separate employee and HR accounts. Page selection and fresh
snapshots worked, but filling the login form immediately failed with
`STALE_REF` (latest snapshot generation 5, bridge reported current generation
14). The employee/HR walkthrough remains unverified in the live browser;
this bridge failure must be carried into the PR validation notes.
