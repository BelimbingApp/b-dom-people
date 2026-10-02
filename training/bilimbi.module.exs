[
  id: "people/training",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_training,
  namespace: Bilimbi.People.Training,
  dependencies: [
    "base/authz",
    "base/artifacts",
    "base/database",
    "base/datetime",
    "base/settings",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_001_060_101 => :bilimbi_only,
    20_261_001_060_201 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Fresh tables are verified after migration, not during baseline adoption.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Training.Contributions,
  dev_seed: nil
]
