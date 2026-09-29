# People Domain for Bilimbi

This repository is the optional People Domain. It mounts in a Bilimbi checkout
at `apps/domains/people`. The thirteen module packages reserve ownership
boundaries. The reference module owns fresh People reference and calendar
tables, a company-scoped operator route, and an API. The workforce module
exposes a scoped native read seam and a per-company operator settings page.
The employee workspace owns People-specific profiles, portal eligibility,
change requests, and saved views, with a workbench under the People menu.
Attendance owns clock facts, day projections, company rules and self view.
Other modules remain empty; no sample rows are installed.

| Module ID | Future ownership |
| --- | --- |
| `people/settings` | People navigation anchor and shared menu groups |
| `people/reference_data` | Company-scoped People references and calendar exceptions |
| `people/workforce` | Scoped native company and employee reads with per-company working statuses |
| `people/employee_workspace` | Employee workbench and People-owned employee facts |
| `people/organisation` | Positions and assignments |
| `people/attendance` | Clock events, day facts, policy settings and self view |
| `people/leave` | Leave policy and balances |
| `people/claims` | Claims and reimbursement |
| `people/skills` | Skills and development |
| `people/training` | Courses, sessions, and learning records |
| `people/performance` | Performance reviews |
| `people/progression` | Progression policy |
| `people/payroll` | Payroll |

## Mount and validate

Clone this repository into `apps/domains/people` in a Bilimbi checkout, then
run from the Bilimbi root:

```sh
mix deps.get
mix bilimbi.composition.lock --pin
BILIMBI_COMPOSITION_PINNED=1 mix deps.get --check-locked
mix precommit
```

Bilimbi discovers the container and modules from their descriptors. The shared
composition lock and manifest live in Bilimbi's ignored
`.scratchpad/composition-lock/` overlay; never commit a lock file here. Removing
the mount removes People code from the next build without deleting durable
data. CI uses the exact Bilimbi revision in
[`.github/bilimbi-revision`](.github/bilimbi-revision) and tests both mounted
and absent compositions.

This is fresh Bilimbi schema work. Future module migrations must have globally
unique versions and declare `:bilimbi_only`; no source People tables or data are
adopted. Add a visible menu leaf only with an implemented route, capability,
scoped behavior, and meaningful empty state. Training remains work in progress.

After mounting, run `mix bilimbi.migrate` from Bilimbi's root. An authorized
operator can open `/people/companies/:company_id/references` for an accessible
company. This route creates reference entries, aliases, and calendar exceptions
without seeding company-specific values. The menu leaf remains hidden because
navigation has no selected company ID to build this explicit route.

The People > Team > Employees menu opens `/people/employees` for the signed-in
actor's validated company. Employee detail shows Core Employee facts read-only
alongside People-owned work profile, portal eligibility, and profile change
requests. Review decisions record history but do not modify Core Employee
identity. Saved views belong to one login actor and company.

Attendance contributes **My attendance** under My work and **Attendance rules**
under Settings. The latter sets the time zone and enables employee self clocking
per company. Its default is off. See `attendance/docs/README.md` for the data
contract and deployment inventory step.

## License

[MIT](LICENSE).
