Code.require_file("../priv/repo/migrations/20261001021001_create_payroll_outputs.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20260930230501_create_payroll_foundation.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20260930230502_create_people_payroll_attendance_rule_pay_items.exs",
  __DIR__
)

defmodule Bilimbi.People.Payroll.MigrationTest do
  use ExUnit.Case, async: false
  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.Payroll.Migrations.{CreateAttendanceRulePayItems, CreateFoundation}
  alias Bilimbi.People.Payroll.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    unique = System.unique_integer([:positive])
    # Separate BEAMs share PostgreSQL; a VM-local integer can name another run's database.
    database = "bilimbi_payroll_migration_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 2},
        id: repo
      )
    )

    Ecto.Migrator.up(Repo, 20_260_930_230_501, CreateFoundation, log: false, dynamic_repo: repo)

    Ecto.Migrator.up(Repo, 20_260_930_230_502, CreateAttendanceRulePayItems,
      log: false,
      dynamic_repo: repo
    )

    Ecto.Migrator.up(Repo, 20_261_001_021_001, Bilimbi.People.Payroll.Migrations.CreateOutputs,
      log: false,
      dynamic_repo: repo
    )

    %{repo: repo}
  end

  test "the fresh migration implements the schema contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "migrated triggers, keys and indexes refuse invalid changes", %{repo: repo} do
    classification =
      insert!(repo, "people_payroll_classifications", %{
        code: "class-a",
        name: "Class A",
        effective_from: ~D[2026-01-01]
      })

    item =
      insert!(repo, "people_payroll_items", %{
        code: "item-a",
        name: "Item A",
        classification_id: classification,
        currency: "AAA",
        amount: Decimal.new("1"),
        effective_from: ~D[2026-01-01]
      })

    period =
      insert!(repo, "people_payroll_periods", %{
        code: "period-a",
        starts_on: ~D[2026-01-01],
        ends_on: ~D[2026-01-31],
        pay_on: ~D[2026-02-01]
      })

    mapping =
      insert!(repo, "people_payroll_mappings", %{
        source_kind: "leave",
        source_key: "1",
        item_id: item,
        effective_from: ~D[2026-01-01]
      })

    attendance_mapping =
      insert!(repo, "people_payroll_attendance_rule_pay_items", %{
        attendance_rule_code: "rule-a",
        item_id: item,
        effective_from: ~D[2026-01-01]
      })

    run = run!(repo, period, "AAA")

    for {table, id} <- [
          {"people_payroll_classifications", classification},
          {"people_payroll_items", item},
          {"people_payroll_periods", period},
          {"people_payroll_mappings", mapping},
          {"people_payroll_attendance_rule_pay_items", attendance_mapping}
        ],
        sql <- [
          "UPDATE #{table} SET updated_at = updated_at WHERE id = $1",
          "DELETE FROM #{table} WHERE id = $1"
        ],
        do: assert_refused(repo, :check_violation, sql, [id])

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(repo, "people_payroll_items", %{
               code: "item-b",
               name: "Item B",
               classification_id: -1,
               currency: "AAA",
               amount: Decimal.new("1"),
               effective_from: ~D[2026-01-01]
             })

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(repo, "people_payroll_mappings", %{
               source_kind: "leave",
               source_key: "2",
               item_id: -1,
               effective_from: ~D[2026-01-01]
             })

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(repo, "people_payroll_attendance_rule_pay_items", %{
               attendance_rule_code: "rule-b",
               item_id: -1,
               effective_from: ~D[2026-01-01]
             })

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             try_run(repo, -1, "AAA")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             try_run(repo, period, "AAA")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert(repo, "people_payroll_periods", %{
               code: "period-a",
               starts_on: ~D[2026-03-01],
               ends_on: ~D[2026-03-31],
               pay_on: ~D[2026-04-01]
             })

    assert_refused(
      repo,
      :check_violation,
      "UPDATE people_payroll_runs SET snapshot = '{}' WHERE id = $1",
      [run]
    )

    assert_refused(repo, :check_violation, "DELETE FROM people_payroll_runs WHERE id = $1", [run])

    assert {:ok, %{num_rows: 1}} =
             SQL.query(
               repo,
               "UPDATE people_payroll_runs SET locked_at = now(), locked_by_actor_id = 91 WHERE id = $1",
               [run]
             )

    for sql <- [
          "UPDATE people_payroll_runs SET locked_at = NULL, locked_by_actor_id = NULL WHERE id = $1",
          "UPDATE people_payroll_runs SET locked_at = now(), locked_by_actor_id = 92 WHERE id = $1",
          "UPDATE people_payroll_runs SET snapshot = '{}' WHERE id = $1",
          "DELETE FROM people_payroll_runs WHERE id = $1"
        ],
        do: assert_refused(repo, :check_violation, sql, [run])
  end

  test "output history is immutable and database stages enforce approval and scope", %{repo: repo} do
    classification =
      insert!(repo, "people_payroll_classifications", %{
        code: "class-a",
        name: "Classification A",
        effective_from: ~D[2026-01-01]
      })

    item =
      insert!(repo, "people_payroll_items", %{
        code: "item-a",
        name: "Item A",
        classification_id: classification,
        currency: "AAA",
        amount: Decimal.new("0.123456"),
        effective_from: ~D[2026-01-01]
      })

    period =
      insert!(repo, "people_payroll_periods", %{
        code: "period-a",
        starts_on: ~D[2026-01-01],
        ends_on: ~D[2026-01-31],
        pay_on: ~D[2026-02-01]
      })

    run = run!(repo, period, "AAA")

    attrs = %{
      run_id: run,
      item_id: item,
      employee_id: 101,
      source_key: "evidence-a",
      evidence: "Governed evidence A",
      on_date: ~D[2026-01-05],
      units: Decimal.new("0.000001"),
      direction: "earning"
    }

    contribution = insert!(repo, "people_payroll_contributions", attrs)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert(repo, "people_payroll_calculations", %{
               run_id: run,
               snapshot: %{},
               digest: String.duplicate("a", 64)
             })

    SQL.query!(
      repo,
      "UPDATE people_payroll_runs SET locked_at = now(), locked_by_actor_id = 93 WHERE id = $1",
      [run]
    )

    line =
      insert!(repo, "people_payroll_result_lines", %{
        run_id: run,
        contribution_id: contribution,
        employee_id: 101,
        direction: "earning",
        amount: Decimal.new("0.000000123456")
      })

    calculation =
      insert!(repo, "people_payroll_calculations", %{
        run_id: run,
        snapshot: %{},
        digest: String.duplicate("a", 64)
      })

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert(repo, "people_payroll_contributions", %{attrs | source_key: "late"})

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert(repo, "people_payroll_decisions", %{
               run_id: run,
               outcome: "approved",
               reason: "Own work"
             })

    assert_refused(
      repo,
      :check_violation,
      "INSERT INTO people_payroll_decisions (tenant_id,company_id,created_by_actor_id,run_id,outcome,reason,inserted_at,updated_at) VALUES (41,73,93,$1,'approved','Locked own setup',now(),now())",
      [run]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert(repo, "people_payroll_documents", %{
               run_id: run,
               kind: "report",
               artifact_id: <<0::128>>
             })

    assert {:ok, %{rows: [[decision]]}} =
             SQL.query(
               repo,
               "INSERT INTO people_payroll_decisions (tenant_id,company_id,created_by_actor_id,run_id,outcome,reason,inserted_at,updated_at) VALUES (41,73,92,$1,'approved','Checked',now(),now()) RETURNING id",
               [run]
             )

    document =
      insert!(repo, "people_payroll_documents", %{
        run_id: run,
        kind: "report",
        artifact_id: <<0::128>>
      })

    for {table, id} <- [
          {"people_payroll_contributions", contribution},
          {"people_payroll_result_lines", line},
          {"people_payroll_calculations", calculation},
          {"people_payroll_decisions", decision},
          {"people_payroll_documents", document}
        ],
        sql <- [
          "UPDATE #{table} SET updated_at = updated_at WHERE id = $1",
          "DELETE FROM #{table} WHERE id = $1"
        ] do
      assert_refused(repo, :check_violation, sql, [id])
    end

    assert_refused(
      repo,
      :check_violation,
      "INSERT INTO people_payroll_contributions (tenant_id,company_id,created_by_actor_id,run_id,item_id,employee_id,source_key,evidence,on_date,units,direction,inserted_at,updated_at) VALUES (41,74,91,$1,$2,101,'foreign','Evidence',CURRENT_DATE,1,'earning',now(),now())",
      [run, item]
    )
  end

  defp run!(repo, period, currency) do
    {:ok, %{rows: [[id]]}} = try_run(repo, period, currency)
    id
  end

  defp try_run(repo, period, currency),
    do:
      insert(repo, "people_payroll_runs", %{
        period_id: period,
        country: "Jurisdiction A",
        currency: currency,
        snapshot: %{"items" => []}
      })

  defp insert!(repo, table, values) do
    {:ok, %{rows: [[id]]}} = insert(repo, table, values)
    id
  end

  defp insert(repo, table, values) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    values =
      Map.merge(values, %{
        tenant_id: 41,
        company_id: 73,
        created_by_actor_id: 91,
        inserted_at: now,
        updated_at: now
      })

    {columns, params} = Enum.unzip(values)
    placeholders = Enum.map_join(1..length(params), ", ", &"$#{&1}")

    SQL.query(
      repo,
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) RETURNING id",
      params
    )
  end

  defp assert_refused(repo, code, sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} = SQL.query(repo, sql, params)
  end
end
