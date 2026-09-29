defmodule Bilimbi.People.ReferenceData.SchemaContract do
  @moduledoc "Fresh Bilimbi reference schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  def migration_version, do: 20_260_930_100_101

  @impl true
  def tables do
    [
      %{
        name: "people_reference_entries",
        columns:
          common_columns("people_reference_entries")
          |> Map.merge(%{
            "kind" => column({:varchar, 80}, false),
            "code" => column({:varchar, 100}, false),
            "label" => column({:varchar, 200}, false),
            "active" => column(:boolean, false, {:boolean, true})
          }),
        indexes: %{
          "people_reference_entries_pkey" => index(["id"], true),
          "people_reference_entries_company_kind_code_unique" =>
            index(["company_id", "kind", "code"], true),
          "people_reference_entries_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_reference_aliases",
        columns:
          common_columns("people_reference_aliases")
          |> Map.merge(%{
            "entry_id" => column(:bigint, false),
            "label" => column({:varchar, 200}, false)
          }),
        indexes: %{
          "people_reference_aliases_pkey" => index(["id"], true),
          "people_reference_aliases_company_label_unique" => index(["company_id", "label"], true),
          "people_reference_aliases_tenant_id_company_id_entry_id_index" =>
            index(["tenant_id", "company_id", "entry_id"])
        },
        foreign_keys: %{
          "people_reference_aliases_entry_id_fkey" => %{
            columns: ["entry_id"],
            references: {"people_reference_entries", ["id"]},
            on_delete: :restrict
          }
        }
      },
      %{
        name: "people_calendar_exceptions",
        columns:
          common_columns("people_calendar_exceptions")
          |> Map.merge(%{
            "on_date" => column(:date, false),
            "label" => column({:varchar, 200}, false)
          }),
        indexes: %{
          "people_calendar_exceptions_pkey" => index(["id"], true),
          "people_calendar_exceptions_company_date_label_unique" =>
            index(["company_id", "on_date", "label"], true),
          "people_calendar_exceptions_tenant_id_company_id_on_date_index" =>
            index(["tenant_id", "company_id", "on_date"])
        },
        foreign_keys: %{}
      }
    ]
  end

  defp common_columns(table) do
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
