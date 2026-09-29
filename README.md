# People Domain for Bilimbi

This repository is the optional People Domain. It mounts in a Bilimbi checkout
at `apps/domains/people`. The thirteen module packages reserve ownership
boundaries. The workforce module now exposes a scoped native read seam; there
are no People business tables, routes, menu entries, or sample rows yet.

| Module ID | Future ownership |
| --- | --- |
| `people/settings` | People operator settings and navigation anchor |
| `people/reference_data` | People references and calendar exceptions |
| `people/workforce` | Scoped native company and employee reads; position reads unavailable until Organisation lands |
| `people/employee_workspace` | People-specific employee work |
| `people/organisation` | Positions and assignments |
| `people/attendance` | Time and attendance |
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

## License

[MIT](LICENSE).
