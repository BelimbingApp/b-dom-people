[
  id: "people/claims",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_claims,
  namespace: Bilimbi.People.Claims,
  dependencies: [
    "base/authz",
    "base/database",
    "base/datetime",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/employee",
    "core/user",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_930_150_101 => :bilimbi_only,
    20_260_930_170_101 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification precedes pending Bilimbi-only migrations.
  # Registering fresh tables here would require them before migration runs.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Claims.Contributions,
  dev_seed: nil
]
