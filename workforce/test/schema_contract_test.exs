Code.require_file(
  "../priv/repo/migrations/20261016090000_create_workforce_employments.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261016093000_create_workforce_employment_exceptions.exs",
  __DIR__
)

defmodule Bilimbi.People.Workforce.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.Workforce.Migrations.CreateWorkforceEmploymentExceptions
  alias Bilimbi.People.Workforce.Migrations.CreateWorkforceEmployments
  alias Bilimbi.People.Workforce.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_workforce_#{String.replace(Ecto.UUID.generate(), "-", "")}"
    quoted = SchemaVerifier.quote_identifier!(database)
    Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "CREATE DATABASE #{quoted}", []) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "DROP DATABASE #{quoted}", []) end)
    end)

    repo = Module.concat(__MODULE__, FreshRepo)

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 2},
        id: repo
      )
    )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_261_016_090_000, CreateWorkforceEmployments,
               log: false,
               dynamic_repo: repo
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_261_016_093_000, CreateWorkforceEmploymentExceptions,
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete employment contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end
end
