Code.require_file(
  "../priv/repo/migrations/20260930120101_create_employee_workspace.exs",
  __DIR__
)

defmodule Bilimbi.People.EmployeeWorkspace.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.EmployeeWorkspace.Migrations.CreateEmployeeWorkspace
  alias Bilimbi.People.EmployeeWorkspace.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_workspace_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
             Ecto.Migrator.up(Repo, 20_260_930_120_101, CreateEmployeeWorkspace,
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete workspace contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end
end
