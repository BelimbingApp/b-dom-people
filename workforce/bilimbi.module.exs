[
  id: "people/workforce",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_workforce,
  namespace: Bilimbi.People.Workforce,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/employee",
    "core/user"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_016_090_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification precedes pending Bilimbi-only migrations.
  # Registering the fresh table here would require it before migration runs.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Workforce.Contributions,
  dev_seed: nil
]
