# Payroll, Performance and Progression menu rollout

The implemented slices meet the menu readiness rows for Payroll foundation and
calculation/output (5C/6A), Performance (7A) and Progression (7B). Navigation
uses the existing shared People containers; Settings owns the new Payroll
container. No business defaults, grants or sample records are installed by
this rollout. The host pin is `cd98044ea278305380e0f7969cf9f347c42ec6fe`.

| Menu location | Route | Required capability |
| --- | --- | --- |
| Payroll > Runs | `/people/payroll/runs` | `people.payroll.view` |
| Payroll > Pay-item mappings | `/people/payroll/setup/mappings` | `people.payroll.view` |
| Settings > Payroll setup | `/people/payroll/setup` | `people.payroll.view` |
| Development > Performance reviews | `/people/performance` | `people.performance.view` |
| Development > Progression | `/people/progression` | `people.progression.policy.view` |
| My work > My standing | `/people/progression/my` | `people.progression.self.view` |

Pay-item mappings belongs to the existing setup workspace. Its leaf opens the
`/people/payroll/setup/mappings` variant, which focuses and scrolls to the
mappings section and highlights only that leaf; Payroll setup highlights the
general page. Switching company keeps the chosen variant. The Attendance
mapping task retains its separate capability and authorized route.
Employee performance self-view has no My work leaf, following the approved
outline. My standing shows a My performance section linking to
`/people/performance/my` for actors holding `people.performance.self.view`, and
both pages highlight My standing. The route stays directly reachable.
Performance insights remains absent because no insights page exists.

## Acceptance evidence

The existing module-owned domain and host tests cover effective-dated payroll
setup, permanent locking, exact decimal replay, independent approval, private
artifacts, versioned performance evidence, release guards and actor-specific
views, and immutable progression publication and eligibility explanations.
Additional host assertions check rendered menu links and capability denial.
Full `mix precommit` passed: 1,043 Web tests, all People domain suites and the
contribution check. The Payroll migration fixture now uses a UUID database
name so separate BEAM processes cannot collide through VM-local counters.
Migration versions, declared graph edges and the host mandate scan also passed.
All three unregistered SchemaContracts were verified against a freshly
migrated task-owned database before browser inspection.

The browser walkthrough uses the real Bilimbi host, real sign-in sessions,
company-scoped capability grants and linked employees. Scratch data and logs
stay outside this repository. Desktop and 390 × 844 mobile snapshots cover:

| Actor | Observed behavior |
| --- | --- |
| Employee | My standing is visible (the walkthrough predates removing the My performance leaf; the My standing link to own performance is covered by LiveView tests); own performance has communicated-target/released-review empty states; progression has a no-policy state and an explicit unknown explanation after publication without evidence. |
| Manager | Performance reviews is visible; review, description, KPI and evidence tasks render; a governed measurement can be recorded. |
| HR | Performance reviews and Progression are visible; release queue starts empty; policy draft, publication confirmation and published history work. |
| Payroll operator | Runs, Pay-item mappings and Payroll setup are visible; company settings save; runs and Leave/Claims mappings have meaningful empty states; the separately authorized Attendance mapping page renders its no-rules state. |
| Actor without access | The People branch is pruned; all seven protected routes, including Attendance mappings, redirect to the dashboard. |

Menu filtering does not grant access. Company validation and action capabilities
remain enforced by the existing LiveViews and public facades. Employees do not
receive payroll review access from this change. No area was held hidden after
these walkthroughs.
