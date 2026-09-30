[
  id: "people/performance",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_performance,
  namespace: Bilimbi.People.Performance,
  dependencies: [
    "base/audit",
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/user",
    "people/organisation",
    "people/settings",
    "people/skills",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_001_070_701 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Fresh tables are verified after migration, not during baseline adoption.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Performance.Contributions,
  dev_seed: nil
]
