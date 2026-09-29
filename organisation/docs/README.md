# Organisation

Module ID: `people/organisation`. Positions and assignments.

`Bilimbi.People.Organisation` owns stable position identities, immutable
effective-dated title versions, and effective-dated employee assignments. A
vacancy leaves the position and its title in place. Substantive assignments
cannot overlap for one position; acting and concurrent cover can. Both interval
ends are inclusive. PostgreSQL exclusion constraints enforce the non-overlap
rules even for concurrent writers. Parent links are company-bound and cycle
checked under the Core Company lock.

Every public operation takes a validated `Bilimbi.Base.Tenancy.Scope` and an
explicit platform company ID. Writes check a live workforce company through
public APIs; assignments accept only an employee that `Workforce.employee/3`
exposes, so agents and employees outside the company's working statuses are
refused. Reads apply the same rule at read time: an assignee who later leaves
the working statuses is omitted from holders and no longer occupies the
position, while the assignment row stays as history. `positions/4` returns at most 100
positions per page; `count_positions/2` supports the explorer's pagination.
The Organisation application registers its read implementation with the
`Bilimbi.People.Workforce.positions/4` seam when mounted. Without Organisation,
that read returns `{:error, :unavailable}`. No Connector table is read.

The authorised `/people/organisation` route has a company and date filter,
bounded pages, and an empty state. Only the complete Organisation leaf is
visible in People > Team. Training and Progression navigation remain hidden.

The `20260930060000` migration is fresh Bilimbi-only schema. It creates three
empty tables and no seed rows. Before running it against any deployment, use a
read-only inventory in each target database to confirm that no existing People
tables contain live data. This local change was validated against a new empty
scratch database; production environment inventories were not available here.
The schema contract checks for partial tables before this migration is recorded
and verifies all three structures and company ownership once it is recorded.
That lets a compatible Base/Core database be verified before pending People
migrations execute.
