[
  id: "people/employee_workspace",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_employee_workspace,
  namespace: Bilimbi.People.EmployeeWorkspace,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/employee",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_930_120_101 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification precedes pending Bilimbi-only migrations.
  # Registering fresh tables here would require them before migration runs.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.EmployeeWorkspace.Contributions,
  dev_seed: nil
]
