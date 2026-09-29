[
  id: "people/workforce",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_workforce,
  namespace: Bilimbi.People.Workforce,
  dependencies: ["base/tenancy", "core/company", "core/employee"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
