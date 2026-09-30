
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
actor's team plans or the capability-protected HR register. Plans record learning
scope, not financial commitments; request approval reserves the money once.
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
policy's period would fall outside the corrected period. Requests and allocations require an enabled currency. Approval
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
