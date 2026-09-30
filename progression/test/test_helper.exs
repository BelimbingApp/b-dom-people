Code.require_file(Path.expand("../../performance/test/test_helper.exs", __DIR__))

Code.require_file(
  Path.expand("../priv/repo/migrations/20261001070801_create_progression.exs", __DIR__)
)

Code.require_file(Path.expand("support/fixtures.ex", __DIR__))
