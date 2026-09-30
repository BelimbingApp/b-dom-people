[
  id: "people/leave",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_leave,
  namespace: Bilimbi.People.Leave,
  dependencies: [
    "base/authz",
    "base/database",
    "base/datetime",
    "base/module_registry",
    "base/queue",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/employee",
    "core/user",
    "people/reference_data",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_930_160_101 => :bilimbi_only,
    20_260_930_190_101 => :bilimbi_only,
    20_260_930_200_101 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification precedes pending Bilimbi-only migrations.
  # Registering fresh tables here would require them before migration runs.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Leave.Contributions,
  dev_seed: nil
]
