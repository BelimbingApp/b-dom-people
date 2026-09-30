Code.require_file(Path.expand("../../../../web/test/test_helper.exs", __DIR__))
Code.require_file(Path.expand("../../organisation/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../skills/test/support/test_fixtures.ex", __DIR__))

Code.require_file(
  Path.expand("../priv/repo/migrations/20261001070701_create_performance.exs", __DIR__)
)

Code.require_file(Path.expand("../test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../test/support/workflow_fixtures.ex", __DIR__))
