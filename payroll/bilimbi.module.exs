[
  id: "people/payroll",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_payroll,
  namespace: Bilimbi.People.Payroll,
  dependencies: [
    "base/authz",
    "base/artifacts",
    "base/database",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/attendance",
    "people/leave",
    "people/workforce",
    "people/claims"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_930_230_501 => :bilimbi_only,
    20_260_930_230_502 => :bilimbi_only,
    20_261_001_021_001 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Payroll.Contributions,
  dev_seed: nil
]
