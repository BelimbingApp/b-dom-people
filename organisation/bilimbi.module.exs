[
  id: "people/organisation",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_organisation,
  namespace: Bilimbi.People.Organisation,
  dependencies: [
    "base/audit",
    "base/authz",
    "base/database",
    "base/menu",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/employee",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_930_060_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  schema_contract: Bilimbi.People.Organisation.SchemaContract,
  contribution_provider: Bilimbi.People.Organisation.Contributions,
  dev_seed: nil
]
