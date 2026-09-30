workspace_apps = Path.expand("../../../..", __DIR__)

for path <- [
      "base/database/test/support/data_case.ex",
      "base/tenancy/test/support/test_fixtures.ex",
      "base/settings/test/support/test_fixtures.ex",
      "core/geonames/test/support/test_fixtures.ex",
      "core/company/test/support/test_fixtures.ex",
      "core/employee/test/support/test_fixtures.ex",
      "core/user/test/support/test_fixtures.ex",
      "base/authz/test/support/company_directory.ex",
      "base/authz/test/support/test_fixtures.ex"
    ],
    do: Code.require_file(Path.join(workspace_apps, path))

Code.require_file(Path.expand("../../organisation/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../skills/test/support/test_fixtures.ex", __DIR__))

Code.require_file(
  Path.expand("../priv/repo/migrations/20261001070701_create_performance.exs", __DIR__)
)

Code.require_file(Path.expand("support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("support/workflow_fixtures.ex", __DIR__))
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
