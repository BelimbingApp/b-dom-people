Code.require_file(
  "../priv/repo/migrations/20260930100101_create_people_reference_data.exs",
  __DIR__
)

defmodule Bilimbi.People.ReferenceData.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.ReferenceData.Migrations.CreateReferenceData
  alias Bilimbi.People.ReferenceData.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_reference_data_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
             Ecto.Migrator.up(Repo, 20_260_930_100_101, CreateReferenceData,
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete reference data contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end
end
