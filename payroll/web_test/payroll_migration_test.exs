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
    database = "bilimbi_people_payroll_migration_#{unique}"
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
