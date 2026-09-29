[
  id: "people/settings",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_settings,
  namespace: Bilimbi.People.Settings,
  dependencies: ["base/module_registry"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Settings.Contributions,
  dev_seed: nil
]
