[
  id: "people/progression",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_progression,
  namespace: Bilimbi.People.Progression,
  dependencies: [
    "base/audit",
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/user",
    "people/performance",
    "people/skills",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_001_070_801 => :bilimbi_only},
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Progression.Contributions,
  dev_seed: nil
]
