defmodule Bilimbi.People.EmployeeWorkspace.SchemaContract do
  @moduledoc "Fresh Bilimbi employee workbench schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  @impl true
  def tables do
    [
      table(
        "people_employee_work_profiles",
        %{
          "employee_id" => column(:bigint, false),
          "work_location" => column({:varchar, 200}, true),
          "work_arrangement" => column({:varchar, 120}, true),
          "notes" => column(:text, true)
        },
        ["company_id", "employee_id"],
        ["tenant_id", "company_id"]
      ),
      table(
        "people_employee_accesses",
        %{
          "employee_id" => column(:bigint, false),
          "portal_enabled" => column(:boolean, false, {:boolean, false}),
          "reason" => column(:text, true)
        },
        ["company_id", "employee_id"],
        ["tenant_id", "company_id"]
      ),
      table(
        "people_employee_change_requests",
        %{
          "employee_id" => column(:bigint, false),
          "field" => column({:varchar, 80}, false),
          "proposed_value" => column({:varchar, 500}, false),
          "reason" => column(:text, true),
          "status" => column({:varchar, 20}, false, {:string, "pending"}),
          "requested_by_actor_id" => column(:bigint, false),
          "reviewed_by_actor_id" => column(:bigint, true),
          "reviewed_at" => column({:timestamp, 0}, true)
        },
        nil,
        ["tenant_id", "company_id", "employee_id"]
      ),
      table(
        "people_employee_saved_views",
        %{
          "actor_id" => column(:bigint, false),
          "name" => column({:varchar, 120}, false),
          "search" => column({:varchar, 200}, true),
          "status" => column({:varchar, 40}, true)
        },
        ["company_id", "actor_id", "name"],
        ["tenant_id", "company_id", "actor_id"]
      )
    ]
  end

  defp table(name, columns, unique_columns, scope_columns) do
    indexes = %{
      "#{name}_pkey" => index(["id"], true),
      scope_index_name(name, scope_columns) => index(scope_columns)
    }

    indexes =
      if unique_columns do
        Map.put(
          indexes,
          "#{name}_#{Enum.join(unique_columns, "_")}_index",
          index(unique_columns, true)
        )
      else
        indexes
      end

    checks =
      if name == "people_employee_change_requests" do
        %{
          "people_employee_change_requests_status_check" => %{
            expression: "status IN ('pending', 'approved', 'rejected')",
            validated: true
          }
        }
      else
        %{}
      end

    %{
      name: name,
      columns: Map.merge(common_columns(name), columns),
      indexes: indexes,
      foreign_keys: %{},
      checks: checks
    }
  end

  defp common_columns(name) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{name}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false),
    do: %{columns: columns, unique: unique, where: nil}

  defp scope_index_name("people_employee_change_requests", _columns),
    do: "people_employee_change_requests_scope_idx"

  defp scope_index_name(name, columns),
    do: "#{name}_#{Enum.join(columns, "_")}_index"
end
