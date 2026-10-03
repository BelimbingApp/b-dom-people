Code.require_file(
  "../priv/repo/migrations/20261001060101_create_people_training_catalog.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261001060201_create_training_participation.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261001060401_create_people_learning_governance.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261002060501_create_training_evaluation.exs",
  __DIR__
)

defmodule Bilimbi.People.Training.ParticipationMigrationTest do
  use ExUnit.Case, async: false
  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo

  alias Bilimbi.People.Training.Migrations.{
    CreateCatalog,
    CreateParticipation,
    CreateLearningGovernance
  }

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    unique = System.unique_integer([:positive])
    database = "bilimbi_training_participation_#{unique}"
    quoted = SchemaVerifier.quote_identifier!(database)
    Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "CREATE DATABASE #{quoted}", []) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(Repo, "DROP DATABASE IF EXISTS #{quoted} WITH (FORCE)", [])
      end)
    end)

    repo = Module.concat(__MODULE__, "Repo#{unique}")

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 3},
        id: repo
      )
    )

    Ecto.Migrator.up(Repo, 20_261_001_060_101, CreateCatalog, log: false, dynamic_repo: repo)

    Ecto.Migrator.up(Repo, 20_261_001_060_201, CreateParticipation,
      log: false,
      dynamic_repo: repo
    )

    Ecto.Migrator.up(Repo, 20_261_001_060_401, CreateLearningGovernance,
      log: false,
      dynamic_repo: repo
    )

    Ecto.Migrator.up(
      Repo,
      20_261_002_060_501,
      Bilimbi.People.Training.Migrations.CreateEvaluation,
      log: false,
      dynamic_repo: repo
    )

    course = insert!(repo, "courses", %{code: "course-a", name: "Course A", active: true})
    event = insert!(repo, "events", %{course_id: course, name: "Event A", capacity: 1})

    session =
      insert!(repo, "session_runs", %{
        event_id: event,
        name: "Session A",
        capacity: 1,
        time_zone: "Etc/UTC",
        starts_at: ~N[2026-10-01 09:00:00],
        ends_at: ~N[2026-10-01 10:00:00]
      })

    %{repo: repo, session: session}
  end

  test "fresh schema matches complete Training contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, Bilimbi.People.Training.SchemaContract.tables())
  end

  test "database refuses mutation, broken scope, revision gaps and capacity overfill", c do
    id = insert!(c.repo, "attendance_facts", fact(c.session, 1, 1, "confirmed", "record-a"))

    for sql <- [
          "UPDATE people_training_attendance_facts SET reason = 'changed' WHERE id = $1",
          "DELETE FROM people_training_attendance_facts WHERE id = $1"
        ],
        do: refused(c.repo, sql, [id])

    assert {:error, %Postgrex.Error{}} =
             insert(c.repo, "attendance_facts", fact(c.session, 1, 3, "absent", "gap"))

    assert {:error, %Postgrex.Error{}} =
             insert(c.repo, "attendance_facts", fact(c.session, 2, 1, "confirmed", "overfill"))

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(
               c.repo,
               "attendance_facts",
               Map.put(fact(c.session, 3, 1, "absent", "scope"), :company_id, 74)
             )

    insert!(c.repo, "attendance_facts", fact(c.session, 1, 2, "absent", "correction"))
    insert!(c.repo, "attendance_facts", fact(c.session, 2, 1, "confirmed", "record-b"))

    evidence =
      insert!(c.repo, "evidence", %{
        fact_id: id,
        artifact_id: Ecto.UUID.dump!(Ecto.UUID.generate())
      })

    refused(c.repo, "DELETE FROM people_training_evidence WHERE id = $1", [evidence])
  end

  test "concurrent confirmations cannot consume the same last place", c do
    results =
      1..2
      |> Enum.map(fn employee ->
        Task.async(fn ->
          insert(
            c.repo,
            "attendance_facts",
            fact(c.session, employee, 1, "confirmed", "concurrent-#{employee}")
          )
        end)
      end)
      |> Enum.map(&Task.await(&1, 10000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Postgrex.Error{}}, &1)) == 1
  end

  defp fact(session, employee, revision, status, key),
    do: %{
      session_id: session,
      employee_id: employee,
      revision: revision,
      status: status,
      reason: "Recorded attendance",
      import_key: key
    }

  defp insert!(repo, suffix, values) do
    {:ok, %{rows: [[id]]}} = insert(repo, suffix, values)
    id
  end

  defp insert(repo, suffix, values) do
    now = ~N[2026-10-01 12:00:00]

    values =
      Map.merge(
        %{tenant_id: 41, company_id: 73, actor_user_id: 91, inserted_at: now, updated_at: now},
        values
      )

    {columns, params} = Enum.unzip(values)
    placeholders = Enum.map_join(1..length(params), ", ", &"$#{&1}")

    SQL.query(
      repo,
      "INSERT INTO people_training_#{suffix} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) RETURNING id",
      params
    )
  end

  defp refused(repo, sql, params),
    do:
      assert(
        {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
          SQL.query(repo, sql, params)
      )
end
