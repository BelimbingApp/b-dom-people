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
    "people/settings"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_930_120_101 => :bilimbi_only},
  web: "priv/web_routes.exs",
  schema_contract: Bilimbi.People.EmployeeWorkspace.SchemaContract,
  contribution_provider: Bilimbi.People.EmployeeWorkspace.Contributions,
  dev_seed: nil
]
