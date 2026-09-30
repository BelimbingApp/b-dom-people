# Progression

Slice 7B owns immutable company progression policy versions and an employee's
eligibility explanation. It does not decide promotion, remuneration, position
assignments or employee status. There are no installed policy rows or universal
skill, outcome or performance-period defaults.

Authorized operators use `/people/progression` to read policy history, draft a
version, and confirm publication. The editor selects an exact published Skills
requirement profile and copies its skill requirements into the policy. It can
also declare a performance period, accepted outcome values and the meaning of
missing performance evidence. These are effective-dated governed policy data,
not application constants. A policy must contain at least one criterion.
Drafts are immutable; correcting a draft or publication means a new version.

The company lock serializes drafting/publication with company lifecycle changes.
A code/version is unique in a company. Publication requires a higher version
than earlier published versions of the same code, and refuses an effective date
earlier than the latest published effective date for that code. An equal date
is a same-day correction: the higher version governs that date. All prior
publications remain readable. Each code is selected independently: its
published version with the latest effective date on or before today, ties
broken by the highest version, governs. A future publication does not remove
the currently effective version. PostgreSQL refuses
changes to published rows and deletion or content edits of any version.
Publication stores the actual login actor and time, and Base Audit captures the
mutation. Writes during impersonation are refused.

`/people/progression/my` derives the employee from the authenticated login actor
and the validated platform company. It accepts no employee selector. Current
Workforce company and employee reads must pass `Workforce.ReadResult`; stale,
unknown and unavailable outcomes cannot become a successful explanation.
Progression needs `people.progression.self.view`. Competence evidence additionally
needs `people.skills.self.view`; performance evidence additionally needs
`people.performance.self.view`. The existing evidence APIs retain their own
permission checks; a missing permission is an unavailable explanation.

Competence compares current finalized skill standing against the exact pinned
profile version and required level. Skills standing now includes assessment
profile/version and scale provenance through its public maps. Missing, expired,
overdue or differently profiled evidence is **unknown**, not a zero score.
Performance reads only the employee's released review versions, within a policy
period, via `Performance.my_records/3`. It selects the most recent period, then
version and identity; corrections retain version/supersession provenance and
explicitly require reevaluation. Draft reviews never count. Missing performance
evidence follows the policy's `unknown` or `not_met` choice. An omitted
performance criterion produces no performance result.

The explanation returns, for each governing policy code, individual
met/not-met/unknown results and a combined status: a failed criterion is not met, otherwise any missing criterion is
unknown, otherwise the declared criteria are met. This result is computed on
read and makes no promotion or pay decision. Employee pages expose meaningful
no-policy, employee-unavailable and permission/freshness states.

Capabilities:

- `people.progression.policy.view`: bounded history, with URL page/page-size state.
- `people.progression.policy.manage`: draft and publish for an authorized company.
- `people.progression.self.view`: the actor's linked employee explanation.

Routes are available for acceptance, while all Progression menu entries remain
hidden pending area rollout acceptance. Training navigation is unchanged.

The fresh table is `people_progression_policy_versions`, owned solely by this
module. Migration `20261001070801` is `:bilimbi_only`; no legacy relation,
migration inventory or adoption contract is reused. The unregistered
`Bilimbi.People.Progression.SchemaContract` verifies freshly migrated structure
via `Bilimbi.Base.Database.SchemaVerifier.verify/2`. The migration's trigger
is exercised through actual PostgreSQL refusal tests. Deployment still requires
a read-only table/row inventory of the target environment; scratch test evidence
is not evidence about production data.

Run Mix commands from the pinned Bilimbi root with People mounted. Focused tests:

```sh
mix test apps/domains/people/progression/test/progression_test.exs
mix test apps/domains/people/progression/web_test/progression_live_test.exs
```

Then run `mix precommit`, composition lock/pin checks, and mounted/absent
validation as described in the repository README. Keep lock overlays in the
Bilimbi scratch directory and validation logs outside the tracked repository.
