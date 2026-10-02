[
  id: "people/reference_data",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_reference_data,
  namespace: Bilimbi.People.ReferenceData,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/settings"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_930_100_101 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already.
  schema_contract: nil,
  contribution_provider: Bilimbi.People.ReferenceData.Contributions,
  dev_seed: nil
]
