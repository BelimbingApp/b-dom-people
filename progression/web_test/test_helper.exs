Code.require_file(Path.expand("../../../../web/test/test_helper.exs", __DIR__))
Code.require_file(Path.expand("../../performance/web_test/test_helper.exs", __DIR__))

Code.require_file(
  Path.expand("../priv/repo/migrations/20261001070801_create_progression.exs", __DIR__)
)

Code.require_file(Path.expand("../test/support/fixtures.ex", __DIR__))
