ExUnit.start()

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

Code.require_file(Path.expand("../../workforce/test/support/authorization_fixtures.ex", __DIR__))
Code.require_file(Path.expand("support/test_fixtures.ex", __DIR__))
