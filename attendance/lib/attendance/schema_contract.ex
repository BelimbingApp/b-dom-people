defmodule Bilimbi.People.Attendance.SchemaContract do
  @moduledoc "Fresh Bilimbi attendance structures."
  @behaviour Bilimbi.Base.Database.SchemaContract

  def migration_version, do: 20_260_930_100_301

  @impl true
  def tables do
    [
      %{
        name: "people_attendance_days",
        columns:
          common("people_attendance_days")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "on_date" => column(:date, false),
            "status" => column({:varchar, 32}, false),
            "first_in_at" => column({:timestamp, 0}, true),
            "last_out_at" => column({:timestamp, 0}, true),
            "worked_minutes" => column(:integer, false, {:integer, 0})
          }),
        indexes: %{
          "people_attendance_days_pkey" => index(["id"], true),
          "people_attendance_days_company_employee_date_unique" =>
            index(["company_id", "employee_id", "on_date"], true),
          "people_attendance_days_tenant_id_company_id_on_date_index" =>
            index(["tenant_id", "company_id", "on_date"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_attendance_clock_events",
        columns:
          common("people_attendance_clock_events")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "day_id" => column(:bigint, false),
            "event_key" => column({:varchar, 160}, false),
            "event_type" => column({:varchar, 16}, false),
            "source" => column({:varchar, 32}, false),
            "occurred_at" => column({:timestamp, 0}, false),
            "timezone" => column({:varchar, 100}, false),
            "actor_user_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_attendance_clock_events_pkey" => index(["id"], true),
          "people_attendance_events_source_key_unique" =>
            index(["company_id", "source", "event_key"], true),
          "people_attendance_clock_events_tenant_id_company_id_employee_id_occurred_at_index" =>
            index(["tenant_id", "company_id", "employee_id", "occurred_at"])
        },
        foreign_keys: %{
          "people_attendance_clock_events_day_id_fkey" => %{
            columns: ["day_id"],
            references: {"people_attendance_days", ["id"]},
            on_delete: :restrict
          }
        }
      }
    ]
  end

  defp common(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}
end
