# Performance

Module ID: `people/performance`. Position descriptions, KPI definitions and
individual targets, observations, reviews and employee responses are owned
here. This is slice 7A; no Progression, salary, Skills score or Training result
is changed by a performance outcome.

All public operations take a validated `Bilimbi.Base.Tenancy.Scope` and an
explicit platform company ID. The performer comes only from its sealed actor
(`Scope.actor/1`), and capabilities are checked with `Authz.can/2`. System
scopes have no person to record and are refused; impersonated writes are
refused rather than attributed as the employee's own act. Company
access is authorized through Core Company; Workforce reads must be current.
Employee identity is resolved through Workforce and the Core User link, never
from form-supplied actor, tenant or company fields. Platform company, workforce
company, provider reference, employee and login actor remain separate values.
No sibling schema is queried. Position versions and placements come from the
Organisation public projection; competency links use the Skills public API.

## Workflow

`draft_description/3` records complete purpose, responsibilities, duties,
authority, qualifications and canonical competency profile ID/version links.
Competency wording remains in Skills. `publish_description/3` rechecks an exact
position version and published profile versions and refuses overlapping
published dates for the same position. A version's content never changes.
Future and historical versions use explicit nonoverlapping inclusive intervals;
an open-ended published interval cannot be silently shortened to fit another
version. Description authority text never grants application permissions.

`define_kpi/3` records a version's unit, measure, source, calculation version,
precision, direction and interpretation. A qualitative rubric needs rubric
text. No executable formula, aggregate score, statutory pack or default KPI is
installed. `propose_target/3` creates an individual target for a current direct
report, with its exact definition version, explicit dates and confidentiality.
`review_target/4` records an independent review rationale;
`publish_target/3` communicates only reviewed, non-confidential targets.
An author or the subject employee cannot approve their own target.
`amend_target/4` preserves the old target and proposes a later effective version
with a reason and a new approval cycle. There is no inferred team attribution,
prorating or performance-to-competence conversion.

`record_observation/3` records attributable textual evidence, source reference
and source version, employee and observation window. `correct_observation/4`
appends a replacement with its reason, retaining the original evidence.
`draft_review/3` requires a published description applicable to the employee's
position at both period boundaries and pins exact communicated target and
observation IDs for that employee and period. The caller states a UTC data
cutoff; evidence and target publication must have been recorded by that cutoff.
`release_review/3` rechecks the assignment, requires pinned evidence and
communicated targets, refuses a future cutoff and records an independent
releaser. Drafts are not employee-visible. PostgreSQL guards enforce immutable
content, valid transitions, scoped links, release prerequisites and closed
review evidence even if an application writer bypasses the facade.

`correct_review/4` creates a new draft with a reason and successor version.
It retains the employee and period and may advance the explicit cutoff to
include late evidence; it cannot move the cutoff backwards. The correction
requires independent release again. Original released rationale, cutoff,
evidence and employee response remain readable exactly as recorded. Each
version has at most one successor. `respond/4` resolves the subject from the
login actor and records one append-only response or dispute per released
version; responding confers no release or approval authority.

## Routes and access

`/people/performance` has Reviews, Position descriptions, KPIs and Evidence
tasks. Record pickers use public workforce and governed record labels.
`reviews/3` lists only reviews authored by the current actor, with URL page
and page-size state. `review/3` reads one authored review; a company-authorized
release approver can also inspect a release candidate. A peer cannot select
someone else's review. Current authorization applies on every read and write,
including revoked grants and cross-company attempts within the same tenant.
Planning pickers and queues show at most the latest 100 records; the authored
review index is paginated. Position choices use a bounded Organisation page.

`/people/performance/my` derives the linked employee from the current account,
shows their communicated targets and released review history and accepts their
response. No linked working employee produces an explicit unavailable state.
Empty companies have no dummy rows. Forged LiveView write events hit a first
`can_*?` deny clause and the facade independently checks the capability.
Publication confirmation holds the selected record on the server and ignores
client-supplied IDs on the confirm event.

| Capability | Authority within the explicitly authorized company |
| --- | --- |
| `people.performance.view` | Authored review history and authorized planning records |
| `people.performance.descriptions.manage` | Prepare and publish description versions |
| `people.performance.kpis.submit` | Measurement definitions and direct-report target proposals/amendments |
| `people.performance.kpis.review` | Independent company target review |
| `people.performance.kpis.approve` | Communicate reviewed, non-confidential company targets |
| `people.performance.reviews.submit` | Direct-report evidence, drafts and author corrections |
| `people.performance.reviews.approve` | Independent company review release and candidate inspection |
| `people.performance.self.view` | The linked employee's communicated targets, released reviews and responses |

The Performance menu contribution is intentionally empty pending the whole
area's rollout acceptance. Routes are capability-gated independently of menu
visibility. Training and Progression stay hidden. No configurable business
names, outcomes, currencies, countries or provider values are hard-coded;
operators author descriptions and measurement definitions/interpretation in
their company. This slice introduces no reminder thresholds or retention policy
that would need a new Base Settings definition or background worker.

## Fresh schema and validation

The migration `20261001070701_create_performance.exs` is fresh Bilimbi-only
schema with a globally unique version, eight empty relations and no dummy rows.
It creates no legacy migration inventory or adoption path. Performance-owned
links use composite tenant/company foreign keys. External employee, position
and competency identities are validated through their owners' public APIs,
without adding sibling table foreign keys or schema contributions.

Run Mix commands from the pinned Bilimbi root. After `mix bilimbi.migrate`,
verify this unregistered fresh contract explicitly:

```elixir
Bilimbi.Base.Database.SchemaVerifier.verify(
  Bilimbi.Base.Repo,
  Bilimbi.People.Performance.SchemaContract.tables()
)
```

`schema_contract: nil` avoids requiring future fresh tables during compatible
Platform verification before migrations run. The contract contains PostgreSQL's
canonical check expressions. Focused domain tests exercise public operations
and make PostgreSQL refuse immutable-history writes; module-owned `web_test/`
tests use the real Web host and cover route gating, actor-specific views,
publication confirmation, forged events, response ownership and URL pagination.

This change was tested only against task-owned scratch databases. All eight
Performance relations were absent in a new database and empty after migration.
No production target database was supplied or inspected. Before deployment,
operators must run read-only table-existence/row-count inventories in both
target environments and stop for a new migration decision if unexpected live
People rows exist. No existing installation is discarded or adopted here.

Live browser verification is deferred for this hidden area: Chrome DevTools AXI
recovered page selection, but the scratch browser fixture did not retain its
authenticated session. The eight real-host LiveView tests passed. Verify desktop
and mobile browser behavior before exposing Performance menu leaves.
