[
  id: "people/payroll",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_payroll,
  namespace: Bilimbi.People.Payroll,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/attendance",
    "people/leave",
    "people/claims"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_930_210_002 => :bilimbi_only,
    20_260_930_230_501 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.People.Payroll.Contributions,
  dev_seed: nil
]
