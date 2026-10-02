# Settings

Module ID: `people/settings`. People operator settings and navigation anchor.

This module contributes the `People` navigation anchor and its shared
`people.my_work` (My work), `people.team` (Team), `people.time_and_expenses`
(Time and expenses), `people.development` (Development), `people.payroll`
(Payroll), `people.reports` (Reports) and `people.settings` (Settings) groups. Modules that place leaves under these
groups depend on `people/settings` rather than defining the groups themselves.
Base Menu hides a node while it has no visible children. It owns no table or
route; reference records and the operator page live in `people/reference_data`.

The Payroll, Performance and Progression leaf placement and its verification
are recorded in [menu-rollout.md](menu-rollout.md).
