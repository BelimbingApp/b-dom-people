# Training courses and sessions

Slice 6B owns a company-scoped course catalog, delivery events, and sessions
with list and calendar views. Courses and **Sessions & calendar** hang under
People > Development. Only actors with the corresponding view capability see
those leaves or reach those routes. Participation, evidence, requests, budgets,
effectiveness, passports and insights remain unimplemented and have no menu
entries. There is no migration inventory, source import, or cutover workflow.

## Public API and scope

`Bilimbi.People.Training` receives a validated `Bilimbi.Base.Tenancy.Scope` and
an explicit **platform company ID** on every persistent operation. The scope's
sealed actor supplies the author and impersonator; callers cannot supply them.
Anonymous/system actors are refused. Cross-company operations require Core
Company's tenant-wide company capability as well as the operation capability.
Cross-tenant records remain out of scope. Archived companies are unavailable.
Workforce reads use `Bilimbi.People.Workforce.ReadResult.require_current/1`;
stale/unavailable workforce results refuse writes and show a recovery message.

Capabilities are `people.training.courses.view`,
`people.training.courses.manage`, `people.training.sessions.view`, and
`people.training.sessions.manage`. Manage does not silently grant view.
Session managers can select active courses through `event_courses/2` without
receiving course-management permission.

The catalog API lists, creates, and updates courses. Operators edit names and
descriptions in place through the shared UI components. Codes are stable and
unique within a company. Operators supply all names and descriptions; no
courses, skills, providers, or countries are seeded. Deactivating a course
prevents new events and retains existing scheduled delivery.

`create_event/3` requires an active course in the same tenant/company.
`create_session/3` requires an event in that company. Both take an explicit
positive whole-number capacity; no capacity default is installed. A session's
capacity cannot exceed its event's capacity. Each session is a delivery of the
same event cohort, so capacities are not summed across sessions. This slice
does not enroll employees, reserve seats, or claim remaining availability;
those facts belong to participation. Events and sessions are create-only in
this slice, and authorship is recorded on each fact.

## Time and calendar contract

Session input requires `starts_local`, `ends_local` (ISO local wall clocks)
and an explicit IANA `time_zone`. `local_instant/2` uses Base DateTime's time
zone database, rejects unknown zones, and refuses DST gaps and overlaps rather
than guessing. End must be strictly after start. UTC instants and the delivery
zone are persisted. No server-local or country-specific zone is assumed.

`calendar/4` returns sessions overlapping a half-open UTC interval:
`starts_at < until` and `ends_at > from`. It includes sessions starting before
the selected window, orders by instant and ID, refuses windows exceeding 366
days, and returns at most 500 rows. The page reports that bound when reached.
The UI selects a month and list/calendar mode through URL filters. Calendar
days use the selected company's operator-managed Base DateTime zone;
multiday sessions appear on each intersected date. List timestamps use the
reader's saved clock through the shared `datetime` component and separately
show the delivery zone. A session form starts with the company zone, which
an operator can change for that delivery. Company timezone remains managed
through the existing Core Company UI and Base Settings.

## Fresh schema and deployment

The migration is declared `:bilimbi_only` with a globally unique version in
`bilimbi.module.exs`. All three `people_training_*` relations are owned here.
Composite foreign keys enforce event/course and session/event tenant/company
identity. Checks enforce positive capacity and ordered instants. Database
triggers enforce session/event capacity and reject unknown stored time zones.
No sibling-private tables are read. No Core or Skills schema is duplicated.

Run Mix from the Bilimbi umbrella root. Before applying the first Training
migration to an existing deployment, inventory the two target environments
read-only for existing People/Training table existence and row counts. The
owner reports no People data to preserve; the disposable validation database
only proves fresh creation and does not certify an existing deployment. Stop
that deployment if unexpected live rows are found and obtain a migration
decision. This migration neither adopts nor deletes source data.

The contract stays unregistered because pre-migration compatibility checking
must not demand pending fresh tables. After `mix bilimbi.migrate`, verify it:

```elixir
Bilimbi.Base.Database.SchemaVerifier.verify(
  Bilimbi.Base.Repo,
  Bilimbi.People.Training.SchemaContract.tables()
)
```

Focused unit and real-host tests are under `training/test` and
`training/web_test`; Web discovers the latter through its test-helper bridge.
