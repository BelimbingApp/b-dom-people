defmodule Bilimbi.People.Workforce.SchemaContract do
  @moduledoc "Fresh Bilimbi People employment schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  @table "people_workforce_employments"
  @exceptions "people_workforce_employment_exceptions"

  @impl true
  def tables do
    [
      %{
        name: @table,
        columns: %{
          "id" => column(:bigint, false, {:sequence, "#{@table}_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "legacy_employee_id" => column(:bigint, false),
          "person_id" => column(:bigint, false),
          "affiliation_id" => column(:bigint, false),
          "employee_number" => column({:varchar, 255}, false),
          "employment_type" => column({:varchar, 255}, false),
          "status" => column({:varchar, 255}, false),
          "employment_start" => column(:date, true),
          "employment_end" => column(:date, true),
          "metadata" => column(:jsonb, true),
          "legacy_created_at" => column({:timestamp, 0}, true),
          "claimed_at" => column({:timestamp, 0}, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "#{@table}_pkey" => index(["id"], true),
          "#{@table}_legacy_employee_id_index" => index(["legacy_employee_id"], true),
          "#{@table}_affiliation_id_index" => index(["affiliation_id"], true),
          "#{@table}_tenant_id_company_id_index" => index(["tenant_id", "company_id"]),
          "#{@table}_company_id_employee_number_index" => index(["company_id", "employee_number"])
        },
        foreign_keys: %{},
        checks: %{}
      },
      %{
        name: @exceptions,
        columns: %{
          "id" => column(:bigint, false, {:sequence, "#{@exceptions}_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "legacy_employee_id" => column(:bigint, false),
          "reason" => column({:varchar, 64}, false),
          "detected_at" => column({:timestamp, 0}, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "#{@exceptions}_pkey" => index(["id"], true),
          "#{@exceptions}_legacy_employee_id_index" => index(["legacy_employee_id"], true),
          "#{@exceptions}_company_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{}
      }
    ]
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false),
    do: %{columns: columns, unique: unique, where: nil}
end
