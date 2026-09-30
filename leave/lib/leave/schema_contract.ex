defmodule Bilimbi.People.Leave.SchemaContract do
  @moduledoc "Fresh Bilimbi leave structures."
  @behaviour Bilimbi.Base.Database.SchemaContract

  def migration_version, do: 20_260_930_160_101

  @impl true
  def tables do
    [
      %{
        name: "people_leave_types",
        columns:
          common("people_leave_types")
          |> Map.merge(%{
            "code" => column({:varchar, 40}, false),
            "name" => column({:varchar, 120}, false),
            "unit" => column({:varchar, 8}, false),
            "paid" => column(:boolean, false),
            "status" => column({:varchar, 16}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "people_leave_types_pkey" => index(["id"], true),
          "people_leave_types_company_code_unique" => index(["company_id", "code"], true),
          "people_leave_types_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_leave_policies",
        columns:
          common("people_leave_policies")
          |> Map.merge(%{
            "leave_type_id" => column(:bigint, false),
            "version" => column(:integer, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true),
            "entitlement" => column({:numeric, 8, 2}, false),
            "actor_user_id" => column(:bigint, true),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "people_leave_policies_pkey" => index(["id"], true),
          "people_leave_policies_type_version_unique" =>
            index(["leave_type_id", "version"], true),
          "people_leave_policies_type_from_unique" =>
            index(["leave_type_id", "effective_from"], true),
          "people_leave_policies_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "people_leave_policies_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          }
        }
      },
      %{
        name: "people_leave_ledger_entries",
        columns:
          common("people_leave_ledger_entries")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "leave_type_id" => column(:bigint, false),
            "leave_year" => column(:integer, false),
            "entry_type" => column({:varchar, 24}, false),
            "quantity" => column({:numeric, 10, 2}, false),
            "unit" => column({:varchar, 8}, false),
            "policy_id" => column(:bigint, true),
            "policy_version" => column(:integer, true),
            "occurred_on" => column(:date, false),
            "source" => column({:varchar, 32}, false),
            "entry_key" => column({:varchar, 160}, false),
            "actor_user_id" => column(:bigint, true),
            "note" => column({:varchar, 500}, true)
          }),
        indexes: %{
          "people_leave_ledger_entries_pkey" => index(["id"], true),
          "people_leave_ledger_entries_source_key_unique" =>
            index(["company_id", "source", "entry_key"], true),
          "people_leave_ledger_entries_tenant_id_company_id_employee_id_leave_year_index" =>
            index(["tenant_id", "company_id", "employee_id", "leave_year"])
        },
        foreign_keys: %{
          "people_leave_ledger_entries_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          },
          "people_leave_ledger_entries_policy_id_fkey" => %{
            columns: ["policy_id"],
            references: {"people_leave_policies", ["id"]},
            on_delete: :restrict
          }
        }
      }
    ]
  end

  # The ledger has no updated_at: entries are append-only.
  defp common(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false)
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}
end
