defmodule Bilimbi.People.Payroll.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Temporary relations consume the typed schema contract. The migration test
  # checks that the real migration implements that contract and its triggers.
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
      "CREATE UNIQUE INDEX payroll_period_code_fixture ON people_payroll_pay_windows(company_id, code)",
      []
    )

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX payroll_run_fixture ON people_payroll_setup_snapshots(period_id, currency)",
      []
    )
  end

  defp sql_type(:uuid), do: "uuid"
  defp sql_type(:bigint), do: "bigint"
  defp sql_type(:date), do: "date"
  defp sql_type(:jsonb), do: "jsonb"
  defp sql_type({:varchar, size}), do: "varchar(#{size})"
  defp sql_type({:numeric, precision, scale}), do: "numeric(#{precision}, #{scale})"
  defp sql_type({:timestamp, precision}), do: "timestamp(#{precision})"
end
