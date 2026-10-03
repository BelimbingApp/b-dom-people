workspace_apps = Path.expand("../../../..", __DIR__)

for path <- [
      "base/tenancy/test/support/test_fixtures.ex",
      "base/settings/test/support/test_fixtures.ex",
      "core/geonames/test/support/test_fixtures.ex",
      "core/company/test/support/test_fixtures.ex",
      "core/employee/test/support/test_fixtures.ex",
      "core/user/test/support/test_fixtures.ex",
      "base/authz/test/support/company_directory.ex",
      "base/authz/test/support/test_fixtures.ex"
    ] do
  Code.require_file(Path.join(workspace_apps, path))
end

# Facade writes authorize the signed-in actor; tests sign one in through the
# shared People fixture.
Code.require_file(Path.expand("../../workforce/test/support/authorization_fixtures.ex", __DIR__))

# Requests count leave days around the public calendar exceptions of
# people/reference_data, so tests create that module's table through its own
# fixture rather than restating its schema here.
Code.require_file(Path.expand("../../reference_data/test/support/test_fixtures.ex", __DIR__))

Code.require_file(Path.expand("support/test_fixtures.ex", __DIR__))
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
