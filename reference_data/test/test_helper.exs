Code.require_file(Path.expand("../../../../base/database/test/support/data_case.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/tenancy/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/geonames/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/company/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/employee/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/user/test/support/test_fixtures.ex", __DIR__))

Code.require_file(
  Path.expand("../../../../base/authz/test/support/company_directory.ex", __DIR__)
)

Code.require_file(Path.expand("../../../../base/authz/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../workforce/test/support/authorization_fixtures.ex", __DIR__))
Code.require_file(Path.expand("support/test_fixtures.ex", __DIR__))

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
