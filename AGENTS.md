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
  are complete. Keep unfinished Progression navigation hidden;
  use the task-based menu outline in the port plan when slices are ready.
  Hang leaves on the outline containers in
  `settings/lib/settings/contributions.ex` rather than declaring a container
  in your module: Base Menu raises on duplicate IDs. Pick menu icons from the
  `hero-{...}` safelist in Bilimbi's `apps/web/assets/css/app.css`; any other
  icon fails `MenuIconSafelistTest`. Refuse write-shaped LiveView events with
  a first `handle_event` deny clause on a `can_*?` assign, as
  `skills/lib/skills/web/catalog_live.ex` does; a hidden button fails Base
  UI's `WriteHandlerGuardTest`.
- Check a module's unregistered `SchemaContract` with
  `Bilimbi.Base.Database.SchemaVerifier.verify/2` against a freshly migrated
  database; write check and partial-index predicates in PostgreSQL's canonical
  form (`pg_get_constraintdef`), as `claims/lib/claims/schema_contract.ex` does.
- Keep the shared composition lock in Bilimbi's ignored
  `.scratchpad/composition-lock/`; never commit a lock here. CI is
  `.github/workflows/ci.yml` and pins Bilimbi via `.github/bilimbi-revision`.
- Use `workforce/docs/README.md` and `Bilimbi.People.Workforce.ReadResult` for
  workforce freshness; consumers should not invent their own status wrapper.
- Authorize every public write, and every public read of private employee
  facts, inside the facade with `Bilimbi.People.Workforce.Authorization`
  (`authorize/3`, `authorize_self/3`, `with_self_employee_lock/4`), taking
  the actor from the scope it was handed. A route capability proven at mount
  or a `can_*?` assign is not authority: a grant revoked, or an account
  unlinked from its employee, while a page stays connected must refuse the
  next event. Do not take an actor or actor ID as a facade argument, and do
  not resolve the signed-in employee once at mount and keep acting on it.
  Tests sign in through `workforce/test/support/authorization_fixtures.ex`.
