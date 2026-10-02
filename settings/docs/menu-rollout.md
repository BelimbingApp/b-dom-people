# Payroll, Performance and Progression menu rollout

The implemented slices meet the menu readiness rows for Payroll foundation and
calculation/output (5C/6A), Performance (7A) and Progression (7B). Navigation
uses the existing shared People containers; Settings owns the new Payroll
container. No business defaults, grants or sample records are installed by
this rollout. The host pin is `1aab4013b99d89259e1ca8259632bedc2582e487`.

| Menu location | Route | Required capability |
| --- | --- | --- |
| Payroll > Runs | `/people/payroll/runs` | `people.payroll.view` |
| Payroll > Pay-item mappings | `/people/payroll/setup/mappings` | `people.payroll.view` |
| Settings > Payroll setup | `/people/payroll/setup` | `people.payroll.view` |
| Development > Performance reviews | `/people/performance` | `people.performance.view` |
| Development > Progression | `/people/progression` | `people.progression.policy.view` |
| My work > My standing | `/people/progression/my` | `people.progression.self.view` OR `people.performance.self.view` |

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
Before the review fixes (the `/people/payroll/setup/mappings` variant, the
My performance leaf removal and per-leaf highlighting), full `mix precommit`
passed: 1,043 Web tests, all People domain suites and the contribution check.
That full run is pre-fix evidence; the review fixes were verified by the
focused Payroll, Performance and Progression LiveView suites and the host menu
route integrity test. The Payroll migration fixture now uses a UUID database
name so separate BEAM processes cannot collide through VM-local counters.
Migration versions, declared graph edges and the host mandate scan also passed.
All three unregistered SchemaContracts were verified against a freshly
migrated task-owned database before browser inspection.

The original browser walkthrough below is pre-fix evidence. It uses the real Bilimbi host, real sign-in sessions,
company-scoped capability grants and linked employees. Scratch data and logs
stay outside this repository. Desktop and 390 × 844 mobile snapshots cover:

| Actor | Observed behavior |
| --- | --- |
| Employee | My performance and My standing are visible (pre-fix: the My performance leaf has since been removed); own performance has communicated-target/released-review empty states; progression has a no-policy state and an explicit unknown explanation after publication without evidence. |
| Manager | Performance reviews is visible; review, description, KPI and evidence tasks render; a governed measurement can be recorded. |
| HR | Performance reviews and Progression are visible; release queue starts empty; policy draft, publication confirmation and published history work. |
| Payroll operator | Runs, Pay-item mappings and Payroll setup are visible; company settings save; runs and Leave/Claims mappings have meaningful empty states; the separately authorized Attendance mapping page renders its no-rules state. |
| Actor without access | The People branch is pruned; all seven protected routes, including Attendance mappings, redirect to the dashboard. |

Menu filtering does not grant access. Company validation and action capabilities
remain enforced by the existing LiveViews and public facades. Employees do not
receive payroll review access from this change. No area was held hidden after
these walkthroughs.

A browser recheck after the review fixes confirmed that My standing shows
Open my performance with no separate My performance leaf, and the link opens
the employee's own performance empty state. Pay-item mappings focuses and
scrolls to its section at desktop and 390 × 844 with no mobile overflow, with
only that leaf marked current; the general setup page marks only Payroll setup.

The My standing leaf and route accept either `people.progression.self.view` or
`people.performance.self.view`, using Bilimbi's any-of capability guard. The
page loads and shows progression explanations only with the progression grant,
and shows the My performance link only with the performance grant. The
performance route and the progression explanation API retain their own grants.
LiveView tests cover all four combinations against a published policy: both
grants show both sections; progression only shows its explanation and denies
the performance route; performance only shows My standing and its performance
link without loading a progression explanation; neither denies both routes and
hides the leaf.

The any-of follow-up was rechecked in the default `chrome-devtools-axi` browser
session against the pinned host, with four real login actors linked to employees
in a task-owned company. Performance only sees My standing and follows Open my
performance to its own records, with My standing highlighted and no progression
section or progression-unavailable message. Progression only sees the no-policy
state and is redirected from the performance route. Both sees the progression
empty state and performance link; neither sees no leaf and is redirected from
both routes. A 390 × 844 mobile check showed no horizontal overflow.
