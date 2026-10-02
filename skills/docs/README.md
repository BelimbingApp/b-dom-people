# Skills

Module ID: `people/skills`. Skill catalog, proficiency scales, requirement
profiles, assessments, reassessment, development actions and reminders.

The catalog slice owns fresh `people_skill_categories`, `people_skills`,
`people_skill_scales`, `people_skill_scale_levels`, `people_skill_profiles`,
`people_skill_profile_items` and `people_skill_profile_selectors` tables. The
assessment slice adds `people_skill_assessments`,
`people_skill_assessment_decisions`, `people_skill_scores`,
`people_skill_reassessment_requests`, `people_skill_action_types`,
`people_skill_actions`, `people_skill_action_events` and
`people_skill_reminders`. Catalog functions take a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit company ID whose
`people/workforce` company read is current. Missing, sibling-company and
cross-tenant records are indistinguishable. Assessment, reassessment, action
and reminder functions take an Authz login actor (`%Bilimbi.Base.Authz.Actor{}`)
and check its capability for that company themselves.

- **Catalog.** Categories and skills have lowercase codes unique per company.
  A skill's code is its stable identity; revisions change its name,
  definition, evidence guide, critical flag and reassessment interval, never
  its code or company. A trigger refuses a direct code change. Nothing is
  deleted: skills and categories are deactivated, and a category with active
  skills cannot be. A skill needs an active category of its own company.
- **Proficiency scales.** A scale code has numbered versions. Only a draft
  takes levels. Publishing needs at least two levels numbered from 0 without
  gaps, with distinct names, an observable anchor and the authority each level
  grants, and retires the previously published version of that code. Later
  changes are a new draft version copied from an existing one. Triggers refuse
  edits to published or retired scales and their levels.
- **Requirement profiles.** A profile code has numbered versions against one
  published scale. A draft lists ordered skill requirements (active skill,
  required level on the scale, criticality, weight and mandatory flag) and
  targets either the whole company or positions exposed by
  `Bilimbi.People.Workforce.positions/4`. Without Organisation mounted, only
  company targets are possible. Publishing needs at least one requirement and
  one target, weights totalling 100, and a start date after the latest
  published version, which is retired the day before. It is refused when
  another code's published or retired version targets any of the same people
  from that date on; a company target overlaps everything. Retiring records the
  last effective day. Items and targets of a published or retired version are
  immutable in the database; the next version is a copied draft. That draft
  adopts the currently published version of its scale code when every
  required level exists on it; otherwise it keeps the earlier scale and
  reports the missing levels. A manager can move any draft to another
  published scale once every required level exists there.
- **Resolution.** `requirements/4` returns the single profile version in force
  on a date for the company, optionally for one position, or `nil`.
  `position_of/4` finds the position an employee substantively holds through
  the Workforce position read; without Organisation mounted only company-wide
  profiles resolve.

## Assessments

An assessor submits `assessed_level` and mandatory `evidence` for one employee
and skill (`submit_assessment/3`). The requirement is resolved on the
assessment date through `requirements/4` and copied onto the assessment with
the profile version and its scale: required level, criticality, weight and
mandatory flag. The level must exist on that scale. The gap, result band
(`exceeds`, `meets`, `minor_gap`, `major_gap`, `critical_gap`) and priority
score (gap times the company's multiplier for the criticality) are computed
once and stored, so later profile or policy changes never rewrite history. The
next review is the validity date, else the assessment date plus the skill's own
`reassessment_months`, else the company default. A `request_key` makes a
resubmission by the same assessor idempotent; a different assessment under the
key is refused.

- **Reach.** Holders of `people.skills.assessments.manage` reach every
  employee of the company. Anyone else reaches only the employees below them
  in the workforce supervisor chain, directly or through others; an actor with
  no linked working employee reaches nobody. Nobody assesses themselves. A
  sibling company is refused by company authorization.
- **Review and finalization.** A submission is `pending_review`. A reviewer
  (`...assessments.review`, within reach) verifies it or returns it with a note;
  a finalizer (`...assessments.approve`) finalizes a verified assessment. The
  assessor and the assessed employee never review or finalize it, and the
  database also refuses a reviewer or finalizer who is the assessor.
- **Corrections.** A returned assessment is corrected by its original assessor
  with a new submission that supersedes it, once. A finalized assessment can be
  corrected by a new one that supersedes it. Assessments are facts: the guard
  trigger admits only the review and finalization columns, only along
  `pending_review` to `verified` or `returned`, and `verified` to `finalized`;
  nothing is deleted. Each step is an append-only row in
  `people_skill_assessment_decisions`.
- **Scores.** Finalizing refreshes `people_skill_scores`, one row per employee
  and skill that mirrors the newest finalized assessment no finalized correction
  supersedes. A trigger refuses a score that does not copy a finalized
  assessment. `standing/2` returns the signed-in employee's scores, with a
  `current`, `overdue` or `expired` state, and their actions and reassessments.
  Score maps also expose `assessment_profile_id`, `assessment_profile_version`
  and `assessment_scale_id`. Consumers comparing levels against a published
  policy must match its pinned profile version; a score from other requirements
  is missing evidence for that policy;
  `gaps/2` lists the scores with a gap inside the actor's reach, mandatory and
  highest priority first; `coverage/3` counts, for company-wide holders, the
  working employees who hold each critical skill at the level their own
  requirement asks and whose validity has not lapsed, against the backup
  minimum.

## Reassessment requests

A team lead (`...reassessments.submit`, within reach, never for themselves)
asks for an employee's skill to be assessed again. The employee needs a current
score, at most one request is open per employee and skill, and it falls due after
the company's request window. A performer (`...reassessments.execute`, who also
holds the submit capability) answers with a normal assessment, which then goes
through review and finalization; the request only records the link, so the score
moves only when that assessment is finalized. A requester or a performer can
cancel a pending request.

## Development actions

Action types are company data with a code, a name and whether the type needs a
trainer or provider; a company starts with none. A manager
(`people.skills.actions.manage`) proposes an action from an employee's current
finalized gap (or an expired critical validity), which copies the gap, or
manually with a stated reason and levels. The priority score and its
explanation are snapshotted. One action exists per source assessment, and a
`request_key` makes a proposal idempotent. An approver
(`people.skills.actions.approve`) other than the proposer and the employee
approves it, which schedules it or marks it not started. The owner (through
`people.skills.actions.update`) or a manager then starts it, holds it, completes
the intervention with evidence and a reassessment date, or cancels it with a
reason; a finalized assessment of the same employee and skill made after
completion closes it as competent (at or above target) or as needing further
action. Every change is an append-only `people_skill_action_events` row, and
completed and cancelled actions are immutable in the database.

Actions follow the assessment reach. A holder of `people.skills.actions.view`
sees, with its history, every action they own and every action for the
employees below them in the supervisor chain; seeing every action in the
company needs `people.skills.actions.manage`.

## Reminders

`due_reminders/3` lists what is due and who would be told: overdue
reassessments and validity ending within the company's window go to the
employee's supervisor (validity also to the employee), overdue actions go to the
action owner, and an under-covered critical skill goes to the company-wide
assessment holders. `issue_reminders/3` writes a ledger row per item, recipient
and period before it sends an in-app Core User notification. The period is the
ISO week, or the month for coverage. The unique key makes a second run in the
same period lose the insert, so nobody is told twice, and `retry_reminders/3`
resends failed rows and rows left pending for more than fifteen minutes by an
interrupted send. An item nobody can be found for writes nothing and is
counted as unaddressed. `enqueue_reminders/2` queues
`Bilimbi.People.Skills.ReminderWorker`, which re-checks the operator's
capability and can be scheduled with Base Schedule. Mail delivery policy is not
part of this slice.

## Policy

Company Base Settings, edited at People > Settings > Skills policy
(`people.skills.policy.manage`): `people.skills.reassessment_due_days`,
`default_reassessment_months`, `reminder_window_days`, `backup_minimum` and the
three `priority_multiplier_*` values for critical, essential and development
requirements. Historical assessments and actions keep the multiplier they used.

Capabilities: `people.skills.catalog.view` opens `/people/skills` (**Skills**
under People > Development) and each profile page;
`people.skills.catalog.manage` edits the catalog, scales, profile drafts and
action types; `people.skills.profiles.publish` publishes and retires profiles.
Assessments use `people.skills.assessments.view` (the **Assessments** page and
its register, gaps and queue), `.submit`, `.review`, `.approve` (finalize) and
`.manage` (reach across the company), plus `people.skills.reassessments.submit`
and `.execute`. **Development actions** needs `people.skills.actions.view`
(owned and in-reach actions), with `.manage` (every action, and proposing),
`.approve` and `.update` (progressing owned actions) for the write steps. **My skills** under My
work needs `people.skills.self.view`. `people.skills.reminders.send` runs
reminders and `people.skills.policy.manage` opens **Skills policy** under
Settings. Split these across roles when the duties need separate people. All
pages have unavailable and empty states, and their write events refuse
callers without the matching capability.

New installations have no categories, skills, scales, profiles, action types or
assessments: category names, level names, criticality weighting and action types
are company data, not defaults. Department targets and department-level
coverage wait for a workforce department read; a Training link to open
reassessment requests after confirmed participation waits for the Training
slice.

The migration versions `20260930181101` (catalog) and `20260930220137`
(assessments) are `:bilimbi_only` and must remain globally unique.
`Bilimbi.People.Skills.SchemaContract` describes the fresh tables; the
descriptor does not register it because compatibility verification runs before
pending Bilimbi-only migrations. It verifies with `SchemaVerifier.verify/2`
against a freshly migrated database. The test fixtures load the guard functions
from the migration files themselves, so tests exercise the shipped triggers.
The workflow tests run in the Web project (`web_test/`) because they authorize
through the host's real Authz. Before deploying, follow the People-table inventory step in
`attendance/docs/README.md`.
