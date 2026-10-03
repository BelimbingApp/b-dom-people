Code.require_file(
  "../priv/repo/migrations/20260930100301_create_people_attendance_core.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20260930180101_create_people_attendance_rosters.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20260930210001_create_people_attendance_allowance_rules.exs",
  __DIR__
)

defmodule Bilimbi.People.Attendance.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.Attendance.Migrations.{CreateCore, CreateRosters, CreateAllowanceRules}
  alias Bilimbi.People.Attendance.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_attendance_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
             Ecto.Migrator.up(Repo, 20_260_930_100_301, CreateCore,
               log: false,
               dynamic_repo: repo
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_930_180_101, CreateRosters,
               log: false,
               dynamic_repo: repo
             )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_260_930_210_001, CreateAllowanceRules,
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete attendance contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end
end
