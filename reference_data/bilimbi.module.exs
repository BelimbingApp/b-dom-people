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
    "core/company"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_930_100_101 => :bilimbi_only},
  web: "priv/web_routes.exs",
  schema_contract: Bilimbi.People.ReferenceData.SchemaContract,
  contribution_provider: Bilimbi.People.ReferenceData.Contributions,
  dev_seed: nil
]
