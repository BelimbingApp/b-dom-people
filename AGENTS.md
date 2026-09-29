# People Domain agent guide

Mount this repository at `apps/domains/people` in Bilimbi. Read Bilimbi's root
`AGENTS.md`, `apps/domains/AGENTS.md`, and
`docs/architecture/0010_composition-model.md` before editing a module. Run Mix
commands from the Bilimbi root. `README.md` gives the mount and pinned
composition-lock commands.

- Keep the container free of `lib/`, `priv/`, and `test/`; each deep module owns
  its package, facade, migrations, schema contract, routes, tests, and docs.
  Declare actual dependencies in its `bilimbi.module.exs` and use public APIs,
  never sibling private tables. Do not add speculative edges to empty modules.
- Use only generic meta-terms for People capabilities: employee, workforce
  company, platform company, provider identity, position, skill, course,
  session, and policy. Customer, vendor, country, currency, course, job, and
  skill names belong in governed data, not identifiers, schema defaults,
  inclusion lists, or fixtures presented as universal defaults.
- Put operator-controlled values in Base Settings with an operator UI. Scope
  company policies and financial currencies explicitly; never hard-code what
  should be configurable. Keep secrets encrypted and out of logs.
- Distinguish platform company, workforce company, provider identity, employee,
  and login actor. Tenant-owned operations require `Bilimbi.Base.Tenancy.Scope`
  and an explicit validated company axis where applicable.
- New People tables are Bilimbi-only fresh schema: declare each migration
  `:bilimbi_only` with a globally unique version. Do not copy legacy table
  names, migration sequences, migration inventory, or dummy rows. Read
  Bilimbi's `docs/architecture/database.md` before persistent work.
- Show a menu leaf only after its route, authorization, scope, and empty state
  are complete. Keep unfinished Training and Progression navigation hidden;
  use the task-based menu outline in the port plan when slices are ready.
- Keep the shared composition lock in Bilimbi's ignored
  `.scratchpad/composition-lock/`; never commit a lock here. CI is
  `.github/workflows/ci.yml` and pins Bilimbi via `.github/bilimbi-revision`.
- Use `workforce/docs/README.md` and `Bilimbi.People.Workforce.ReadResult` for
  workforce freshness; consumers should not invent their own status wrapper.
