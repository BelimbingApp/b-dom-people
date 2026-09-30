# People Domain for Bilimbi

This repository is the optional People Domain. It mounts in a Bilimbi checkout
at `apps/domains/people`. The thirteen module packages reserve ownership
boundaries. The reference module owns fresh People reference and calendar
tables, a company-scoped operator route, and an API. The workforce module
exposes a scoped native read seam and a per-company operator settings page.
The employee workspace owns People-specific profiles, portal eligibility,
change requests, and saved views, with a workbench under the People menu.
Attendance owns clock facts, day projections, company rules, shift templates,
published rosters, clocking locations, adjustment approvals and self view.
Leave owns types, effective-dated entitlement policies, a balance ledger,
requests with approval, and year-end carry-forward.
The claims module owns the claim catalog, effective-dated claim policies,
assignments, employee claim requests, approval, reimbursement, and hand-off
batches.
Organisation owns fresh position tables, versioned titles, assignments, a
bounded explorer, and the Workforce position read. Skills owns the skill
catalog, versioned proficiency scales and requirement profiles, evidence-backed
assessments with independent review, reassessment requests, development actions
and reminders.
Payroll owns periods, effective-dated pay items and classifications,
Leave/Claims and Attendance allowance mappings, and immutable frozen setup
runs. Its menu remains hidden pending the whole payroll area.
Performance owns position-description versions, KPI definitions and governed
individual targets, attributable observations, independently released reviews
and employee responses.
Training owns a company-scoped course catalog, delivery events and a session
calendar with explicit capacity and IANA time zones, append-only attendance
corrections and private evidence through Base Artifacts. Training also owns
governed learning requests, versioned team plans and effective-dated company
budgets; these workflows use direct authorized routes while their menu leaves
stay hidden.
