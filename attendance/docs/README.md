# Attendance

Module ID: `people/attendance`. Time and attendance.

This slice owns fresh `people_attendance_days` and `people_attendance_clock_events`
tables. `Attendance.record_clock/4` validates a live workforce employee in an
explicit company, deduplicates by company/source/key, and projects the day from
ordered events. A conflicting replay is refused. The first clock-in and last
clock-out provide a raw worked span; roster, breaks, late time and approvals
belong to the later roster slice. No payroll claim follows from this projection.

The operator page `/people/attendance/rules` sets each company's attendance
time zone and whether linked employee accounts may clock themselves. The default
is UTC with self clocking off. `/people/attendance/my` resolves the logged-in
Core User to a Core Employee through public APIs and shows up to 31 recent days.
It has explicit unavailable and empty states. Both routes require their own
capability and the operator page selects only authorized active companies.

Before deploying the first People schema migration, operators must inventory
both intended target databases with read-only table existence and row counts
for `people_%` relations. The repository has no access to those environments;
this change cannot certify their inventory. If unexpected rows exist, stop the
deployment and obtain a migration decision. Run `mix bilimbi.migrate` only from
the Bilimbi root after that check.
