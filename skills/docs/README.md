# Skills

Module ID: `people/skills`. Skill catalog, proficiency scales and requirement
profiles.

This slice owns fresh `people_skill_categories`, `people_skills`,
`people_skill_scales`, `people_skill_scale_levels`, `people_skill_profiles`,
`people_skill_profile_items` and `people_skill_profile_selectors` tables. Call
`Bilimbi.People.Skills` with a validated `Bilimbi.Base.Tenancy.Scope` and an
explicit company ID whose `people/workforce` company read is current. Missing,
sibling-company and cross-tenant records are indistinguishable.

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
  immutable in the database; the next version is a copied draft.
- **Resolution.** `requirements/4` returns the single profile version in force
  on a date for the company, optionally for one position, or `nil`.
  Assessments and gaps belong to the assessment slice.

Capabilities: `people.skills.catalog.view` opens `/people/skills` (**Skills**
under People > Development) and each profile page;
`people.skills.catalog.manage` edits the catalog, scales and profile drafts;
`people.skills.profiles.publish` publishes and retires profiles. Split the last
two across roles when drafting and publication need separate people. Both
pages have unavailable and empty states.

New installations have no categories, skills, scales or profiles: category
names, level names and criticality weighting are company data, not defaults.
The backup-coverage and reassessment settings arrive with the assessment
slice that uses them. Department targets wait for a workforce department read.

The migration version `20260930181101` is `:bilimbi_only` and must remain
globally unique. `Bilimbi.People.Skills.SchemaContract` describes the fresh
tables; the descriptor does not register it because compatibility
verification runs before pending Bilimbi-only migrations. The test fixtures
load the guard functions from the migration file itself, so tests exercise the
shipped triggers. Before deploying, follow the People-table inventory step in
`attendance/docs/README.md`.
