# Training courses, sessions and participation

Slices 6B and 6C own a company-scoped course catalog, delivery events, sessions,
confirmed attendance, corrections as history, and private evidence.
Authorized direct routes are `/people/training/courses`,
`/people/training/sessions`, and `/people/training/records`.
All Training menu leaves stay hidden until the whole area's acceptance passes.
There is no legacy migration inventory, source adoption or cutover workflow.
Requests, budgets, effectiveness, passports and insights remain later slices.

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
`people.training.sessions.manage`; participation capabilities are listed under
[Participation and evidence](#participation-and-evidence). Manage does not
silently grant view.
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
`day_start/2` bounds each month at the first instant of its local day, so a
DST gap or overlap at local midnight never blanks the page. Multiday sessions
appear on each intersected date. List timestamps use the reader's saved clock through the shared `datetime` component and separately
show the delivery zone. A session form starts with the company zone, which
an operator can change for that delivery. Company timezone remains managed
through the existing Core Company UI and Base Settings.

## Fresh schema and deployment

Each migration is declared `:bilimbi_only` with a globally unique version in
`bilimbi.module.exs`. All five `people_training_*` relations are owned here.
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
decision. These migrations neither adopt nor delete source data.

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

## Participation and evidence

`Bilimbi.People.Training.Participation.record/3` takes an explicit company,
session, current workforce employee, attendance status (`confirmed` or
`absent`), reason and company-unique `import_key`. The key is a durable
operational import identity, unrelated to migration-source inventory.
Replaying an identical key and payload returns the original fact, including
its actor and revision. Changing the payload refuses with `:import_conflict`;
a correction uses a new key and reason and appends the next revision.
Importing a batch means calling this seam for each row; retrying a partial
batch uses the same keys. No history is overwritten.

Current attendance is the last revision for each session/employee. Confirmed
attendance occupies a session place; an absent correction releases it. The
session lock serializes writers; migrated database triggers also enforce
capacity and consecutive revisions and prohibit fact/evidence updates and
deletions. Lowering capacity below confirmed attendance is refused. Employee
IDs are workforce subject identity; the sealed login actor supplies authorship
and impersonation, never an employee ID supplied as an actor.

The records page shows the most recent 500 sessions and all revisions for the
selected session. Evidence attaches to a particular immutable revision and
does not silently move when attendance is corrected.
`history/3`, `sessions/2`, and `evidence/3` require
`people.training.records.view`. `record/3` and `employees/2` require
`people.training.records.manage`. Uploads require
`people.training.evidence.manage`; retention requires
`people.training.retention.manage`. None grants another capability.
Permissions and company/workforce status are rechecked on every operation,
including requests from a page opened before permission revocation.

`attach/4` accepts PDF bytes with a PDF header, checks the scoped fact, then
calls `Bilimbi.Base.Artifacts.put/6` outside any outer Repo transaction.
The header is a format gate, not a full PDF safety scanner. Base enforces its
operator-configured maximum size. Training stores only the document ID and
provenance; it never stores bytes, paths, reusable access tokens or public URLs.
If linking fails, Base deletion is attempted; an interrupted unlinked document
still expires through Base's owner-scoped retention. The authenticated download
route calls Base `read/4` on every request and sends an attachment with
`private, no-store` and `nosniff` headers.

Use the authoritative [Base Artifacts integration guide](https://github.com/BelimbingApp/bilimbi/blob/9aa523905db2c70865fa3e4347747900370acb42/apps/base/artifacts/README.md)
for private storage provisioning, PDF contracts and operator settings.
An operator configures `artifacts.storage_root`, `artifacts.retention_days`,
maximum bytes and purge retry/hold settings at `/system/settings`.
Unset retention or storage refuses uploads. Expiry is captured at upload;
changing retention affects new documents. Expired documents refuse reads before
cleanup. Training keeps the historical reference after bytes are purged.

The records page exposes a bounded, explicit **Purge expired evidence** action
for retention operators and lists Base purge holds with retry actions.
`purge/2`, `purge_holds/2` and `retry_purge/3` are the matching API seams.
The current slice requires an authenticated user for maintenance and installs
no automatic schedule or system principal. Base records read/delete/purge
audits and handles retries, tombstones and held documents; Training does not
implement a second retention worker or file store.
