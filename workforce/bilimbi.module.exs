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
  migrations: nil,
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Workforce.Contributions,
  dev_seed: nil
]
