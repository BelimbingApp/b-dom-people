[
  id: "people/attendance",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_attendance,
  namespace: Bilimbi.People.Attendance,
  dependencies: [
    "base/audit",
    "base/authz",
    "base/database",
    "base/datetime",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/user",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_930_100_301 => :bilimbi_only,
    20_260_930_180_101 => :bilimbi_only,
    20_260_930_210_001 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Attendance.Contributions,
  dev_seed: nil
]
