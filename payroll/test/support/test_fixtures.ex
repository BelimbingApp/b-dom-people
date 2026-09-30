defmodule Bilimbi.People.Payroll.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Temporary relations consume the typed schema contract. Fresh migration
  # verification separately checks that PostgreSQL implements that contract.
  def create_tables! do
    for table <- Bilimbi.People.Payroll.SchemaContract.tables() do
      columns =
        Enum.map(table.columns, fn {name, column} ->
          type = if name == "id", do: "bigserial PRIMARY KEY", else: sql_type(column.type)
          "#{name} #{type}" <> if(column.nullable, do: "", else: " NOT NULL")
        end)

      checks =
        Enum.map(table.checks, fn {name, spec} ->
          "CONSTRAINT #{name} CHECK (#{spec.expression})"
        end)

      SQL.query!(
        Repo,
        "CREATE TEMPORARY TABLE #{table.name} (#{Enum.join(columns ++ checks, ", ")}) ON COMMIT DROP",
        []
      )
    end

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX payroll_period_code_fixture ON people_payroll_periods(company_id, code)",
      []
    )

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX payroll_run_fixture ON people_payroll_runs(period_id, currency)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.payroll_guard_run() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' OR OLD.locked_at IS NOT NULL THEN
          RAISE EXCEPTION 'payroll run cannot change' USING ERRCODE = '23514';
        END IF;
        IF (to_jsonb(NEW) - 'locked_at' - 'locked_by_actor_id' - 'updated_at') IS DISTINCT FROM
           (to_jsonb(OLD) - 'locked_at' - 'locked_by_actor_id' - 'updated_at') OR NEW.locked_at IS NULL THEN
          RAISE EXCEPTION 'only payroll run locking is permitted' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE TRIGGER payroll_guard BEFORE UPDATE OR DELETE ON people_payroll_runs FOR EACH ROW EXECUTE FUNCTION pg_temp.payroll_guard_run()",
      []
    )
  end

  defp sql_type(:bigint), do: "bigint"
  defp sql_type(:date), do: "date"
  defp sql_type(:jsonb), do: "jsonb"
  defp sql_type({:varchar, size}), do: "varchar(#{size})"
  defp sql_type({:numeric, precision, scale}), do: "numeric(#{precision}, #{scale})"
  defp sql_type({:timestamp, precision}), do: "timestamp(#{precision})"
end
