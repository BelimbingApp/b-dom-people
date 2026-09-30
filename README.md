# People Domain for Bilimbi

This repository is the optional People Domain. It mounts in a Bilimbi checkout
at `apps/domains/people`. The thirteen module packages reserve ownership
boundaries. The reference module owns fresh People reference and calendar
tables, a company-scoped operator route, and an API. The workforce module
exposes a scoped native read seam and a per-company operator settings page.
The employee workspace owns People-specific profiles, portal eligibility,
change requests, and saved views, with a workbench under the People menu.
Attendance owns clock facts, day projections, company rules, shift templates,
published rosters, clocking locations, adjustment approvals and self view.
Leave owns types, effective-dated entitlement policies, a balance ledger,
requests with approval, and year-end carry-forward.
The claims module owns the claim catalog, effective-dated claim policies,
assignments, employee claim requests, approval, reimbursement, and hand-off
batches.
Organisation owns fresh position tables, versioned titles, assignments, a
bounded explorer, and the Workforce position read. Skills owns the skill
catalog, versioned proficiency scales and requirement profiles, evidence-backed
assessments with independent review, reassessment requests, development actions
and reminders.
Payroll owns periods, effective-dated pay items and classifications, Leave/Claims
mappings and immutable frozen setup runs. Its menu remains hidden pending the
whole payroll area; attendance mappings are not available yet.
Performance owns position-description versions, KPI definitions and governed
individual targets, attributable observations, independently released reviews
and employee responses. Other modules remain empty;
no sample rows are installed.

| Module ID | Ownership |
| --- | --- |
| `people/settings` | People navigation anchor and shared menu groups |
| `people/reference_data` | Company-scoped People references and calendar exceptions |
| `people/workforce` | Scoped native company, employee and optional position reads with per-company working statuses |
| `people/employee_workspace` | Employee workbench and People-owned employee facts |
| `people/organisation` | Versioned positions, assignments, and explorer |
| `people/attendance` | Clock events, day facts, rules, rosters, clocking locations and adjustments |
| `people/leave` | Leave types, policies, balance ledger, requests, approval and carry-forward |
| `people/claims` | Claim catalog, policies, currencies, requests, approval, and reimbursement |
| `people/skills` | Skill catalog, requirement profiles, assessments, reassessment, development actions and reminders |
| `people/training` | Courses, sessions, and learning records |
| `people/performance` | Position descriptions, KPI targets, versioned evidence and performance reviews |
| `people/progression` | Progression policy |
| `people/payroll` | Payroll periods, catalog versions, mappings and frozen setup |

## Mount and validate

Clone this repository into `apps/domains/people` in a Bilimbi checkout, then
run from the Bilimbi root:

```sh
mix deps.get
mix bilimbi.composition.lock --pin
BILIMBI_COMPOSITION_PINNED=1 mix deps.get --check-locked
mix precommit
```

Bilimbi discovers the container and modules from their descriptors. The shared
composition lock and manifest live in Bilimbi's ignored
`.scratchpad/composition-lock/` overlay; never commit a lock file here. Removing
the mount removes People code from the next build without deleting durable
data. CI uses the exact Bilimbi revision in
[`.github/bilimbi-revision`](.github/bilimbi-revision) and tests both mounted
and absent compositions.

This is fresh Bilimbi schema work. Future module migrations must have globally
unique versions and declare `:bilimbi_only`; no source People tables or data are
adopted. Add a visible menu leaf only with an implemented route, capability,
scoped behavior, and meaningful empty state. Training remains work in progress.

After mounting, run `mix bilimbi.migrate` from Bilimbi's root. An authorized
operator can open `/people/companies/:company_id/references` for an accessible
company. This route creates reference entries, aliases, and calendar exceptions
without seeding company-specific values. The menu leaf remains hidden because
navigation has no selected company ID to build this explicit route.

The People > Team > Employees menu opens `/people/employees` for the signed-in
actor's validated company. Employee detail shows Core Employee facts read-only
alongside People-owned work profile, portal eligibility, and profile change
requests. Review decisions record history but do not modify Core Employee
identity. Saved views belong to one login actor and company.

Attendance contributes **My attendance** under My work, **Rosters** and
**Attendance approvals** under Team, and **Attendance rules** (with shift
template and clocking location tabs) under Settings. See
`attendance/docs/README.md` for the rules, their defaults, the roster and
adjustment workflows, the data contract, and the deployment inventory step.

Leave contributes **My leave** under My work for balances, requests and
cancellation, **Leave approvals** under Team for independent approvers, and
**Leave policies** under Settings for each company's leave year, request rules,
types, policy versions, grants and carry-forward. See `leave/docs/README.md`.

People > My work > My claims opens `/people/claims` for the signed-in actor's
linked working employee. People > Settings > Claim policies opens
`/people/claims/setup`, where an operator chooses a company's claim currencies,
categories, claim types, assignments, and effective-dated limits. A new company
has no claim currency, so it accepts no claims until an operator sets one.
People > Time and expenses > Claim operations opens `/people/claims/operations`
for approvers: decide claims, record reimbursement, and hand approved claims
off in per-currency batches with a CSV export. See `claims/docs/README.md`.

People > Development > Skills opens `/people/skills`, where an operator
maintains a company's skill categories, skills, proficiency scales and
requirement profiles, and a publisher publishes or retires profile versions.
People > Development > Assessments opens `/people/skills/assessments`, where
assessors submit evidence-backed assessments, independent reviewers and
finalizers decide them, and team leads request reassessments. People >
Development > Development actions opens `/people/skills/actions`; People > My
work > My skills shows an employee's own standing; and People > Settings >
Skills policy holds the company's reassessment, priority and reminder settings,
action types and the reminder run. See `skills/docs/README.md`.

Payroll foundation is available for authorized review at `/people/payroll/setup`.
See `payroll/docs/README.md` for explicit country/currency settings, effective
versions and permanent run locking. Calculation and outputs are not implemented.

Performance is available by direct authorized routes at `/people/performance`
for planning and authored reviews, and `/people/performance/my` for the login
actor's own linked employee. Published content and evidence remain immutable;
corrections append versions with reasons. Performance menu leaves remain hidden
until the entire area's rollout acceptance is complete. See
`performance/docs/README.md` for capabilities, release guards and verification.

## License

[MIT](LICENSE).
