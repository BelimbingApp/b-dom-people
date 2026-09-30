# Attendance

Module ID: `people/attendance`. Time and attendance, including allowance
rule data used by Payroll.

Every public function on `Bilimbi.People.Attendance` takes a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit platform company ID, and reads
companies and employees only through `people/workforce`. A stale or unavailable
workforce read refuses the operation.

## Clock facts and days

This module owns fresh `people_attendance_days` and
`people_attendance_clock_events` tables. `Attendance.record_clock/4` validates a
live workforce employee in an explicit company, deduplicates by
company/source/key, and projects the day from ordered events. A conflicting
replay is refused. The first clock-in and last clock-out provide a raw worked
span. A shift belongs to the day of its clock-in: a clock-out after local
midnight closes the previous day's open shift when it falls within the
company's maximum shift length (default 16 hours). A day with a clock-in and no
clock-out is `in_progress` until that length passes, then reads as
`exception_pending` for a missed clock-out. A clock-out past that length is
recorded but does not close the shift; the day stays `exception_pending` for a
supervisor to review. Breaks, late time and overtime are not computed yet, and
no payroll claim follows from this projection.

A clock event may carry `latitude` and `longitude`. The event records the
nearest active clocking location whose radius contains the point. When the
company requires a clocking location, an event without coordinates is refused
with `:location_required` and one outside every active location with
`:outside_clocking_location`.

## Shift templates and rosters

`people_attendance_shift_templates` holds each company's shifts: a code, name,
start and end as minutes past local midnight, and break minutes. An end at or
before the start crosses midnight. Templates are retired, not deleted, so
published rosters keep their meaning.

`people_attendance_roster_entries` holds one entry per employee and date. The
working value (`kind`: `shift`, `rest`, or `none` for a planned removal) is what
planners edit. `published_kind` and its template are what employees see.
`plan_roster_entry/6` edits the working value; clearing a never-published
entry removes it. `publish_roster/5` copies every pending working value in a
period of at most 31 days into the published value in one transaction and
records a `people.attendance.roster_published` Base Audit action. `roster/5`
returns a planner's grid for up to 31 days and 200 employees, with an optional
name or number search. Its pending count covers every pending entry of the
company in the period, including employees the grid does not show, because
publishing releases all of them. `self_roster/5` returns only published entries
for the signed-in actor's linked employee.

## Adjustment requests

`people_attendance_adjustment_requests` records missed clock events that an
employee asks to add. `submit_adjustment/4` resolves the signed-in user to their
linked working employee, reads the local time in the company's attendance time
zone, and refuses a future time, a date outside the company's request window,
and a second pending or approved request for the same event. The request key
makes a resubmission idempotent. The employee may cancel a pending request.

`decide_adjustment/6` locks the pending request. The requester and any account
linked to the same employee cannot decide it (`:self_approval`), and a
rejection needs a note. Approval writes the clock event through the normal
ingestion path with source `adjustment`, key `request:<id>`, and the approver
as actor, so the day is re-projected. The approver's decision is the evidence,
so an approved adjustment is exempt from the location requirement. Each
decision records a `people.attendance.adjustment_<status>` Base Audit action.

## Read bounds

These fixed bounds keep one page render or transaction small; they are
engineering limits, not operator settings. A roster read or publish covers at
most 31 days (`@max_days`) and the planner grid shows at most 200 employees
(`@max_employees`, with a notice to search). My attendance shows the next 14
days of published shifts (`@roster_days`) and the 20 most recent adjustment
requests (`@self_limit`). The approvals queue loads the 200 oldest pending
requests (`@queue_limit`).

## Company rules

These company-scoped Base Settings are edited on the operator page
`/people/attendance/rules` (People > Settings > Attendance rules):

| Setting | Default | Meaning |
| --- | --- | --- |
| `people.attendance.timezone` | `Etc/UTC` | Local date and time for clock events, rosters and requests |
| `people.attendance.max_shift_hours` | 16 | Hours after clock-in that a shift stays open (1–24) |
| `people.attendance.self_clock_enabled` | off | Linked employee accounts may clock themselves |
| `people.attendance.location_required` | off | Clock events need coordinates inside an active clocking location |
| `people.attendance.adjustment_window_days` | 7 | Days, counting today, for which an employee may request an adjustment (1–366) |

The same page links to `/people/attendance/rules/shifts` and
`/people/attendance/rules/locations`, where operators add and retire shift
templates and clocking locations. No shifts, locations or roster rows are
seeded.

## Allowance rules and Payroll source

Operators manage a company's effective-dated allowance catalog at
`/people/attendance/rules/allowances` with the separate
`people.attendance.allowances.manage` capability. Each version carries an
operator code and name, a generic unit, a positive value, an explicit
three-letter currency, and inclusive effective dates. A code cannot have
overlapping periods. New versions preserve earlier values; an operator can
retire a version without deleting its history. There are no seeded codes,
units, rates, or currencies.

`Attendance.payroll_allowance_sources/3` returns only active rules effective
on the requested date as schema-free values (`id`, `code`, `name`, `unit`,
`value`, `currency`, and effective dates). It validates the explicit company
through Workforce before reading. Payroll uses that API to offer source rules
for company pay-item mapping. The API exposes the allowance catalog; it does
not calculate attendance quantities or payroll amounts.

The allowance rule editor is available by its scoped route and setup tab. It
does not add a navigation menu leaf while the broader Payroll and Attendance
allowance area remains under acceptance.

## Pages and capabilities

| Route | Menu | Capability |
| --- | --- | --- |
| `/people/attendance/my` | People > My work > My attendance | `people.attendance.self.view` |
| `/people/attendance/rosters` | People > Team > Rosters | `people.attendance.roster.manage` |
| `/people/attendance/approvals` | People > Team > Attendance approvals | `people.attendance.adjustments.approve` |
| `/people/attendance/rules` and its `shifts` and `locations` tabs | People > Settings > Attendance rules | `people.attendance.rules.manage` |

Operator pages list only active companies the actor may manage under the
page's capability; the selected company is in the URL. My attendance resolves
the logged-in Core User to a Core Employee through public APIs. It shows
clocking, the next 14 days of published shifts, up to 31 recent days, and the
employee's adjustment requests, with explicit unavailable and empty states.

A browser page cannot report a location yet: a Domain module's colocated hook
is not bundled into the Web assets. When a company requires a clocking
location, My attendance hides web clocking and points the employee to a
clocking point or an adjustment request.

## Deployment

Before deploying the first People schema migration, operators must inventory
both intended target databases with read-only table existence and row counts
for `people_%` relations. The repository has no access to those environments;
this change cannot certify their inventory. If unexpected rows exist, stop the
deployment and obtain a migration decision. Run `mix bilimbi.migrate` only from
the Bilimbi root after that check. `Bilimbi.People.Attendance.SchemaContract`
describes both attendance migrations and verifies against a freshly migrated
database with `Bilimbi.Base.Database.SchemaVerifier.verify/2`; it is not
registered in the descriptor, because pending Bilimbi-only migrations would
otherwise fail compatibility verification.
