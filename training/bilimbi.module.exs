[
  id: "people/training",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_training,
  namespace: Bilimbi.People.Training,
  dependencies: [
    "base/authz",
    "base/artifacts",
    "base/database",
    "base/datetime",
    "base/settings",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "core/user",
    "people/settings",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_001_060_101 => :bilimbi_only,
,
    20_261_001_060_401 => :bilimbi_only
