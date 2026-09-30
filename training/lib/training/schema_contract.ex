defmodule Bilimbi.People.Training.SchemaContract do
  @moduledoc "Fresh Bilimbi training catalog and calendar structure. Verify after migration."
  @behaviour Bilimbi.Base.Database.SchemaContract
  @impl true
  def tables do
    [
      table(
        "courses",
        %{
          "code" => column({:varchar, 80}, false),
          "name" => column({:varchar, 160}, false),
          "description" => column(:text, true),
          "active" => column(:boolean, false)
        },
        %{
          "people_training_courses_company_id_code_index" => index(["company_id", "code"], true),
          "people_training_courses_id_tenant_id_company_id_index" =>
            index(["id", "tenant_id", "company_id"], true)
        }
      ),
      table(
        "events",
        %{
          "course_id" => column(:bigint, false),
          "name" => column({:varchar, 160}, false),
          "capacity" => column(:integer, false)
        },
        %{
          "people_training_events_id_tenant_id_company_id_index" =>
            index(["id", "tenant_id", "company_id"], true)
        },
        %{
          "people_training_events_course_scope" =>
            foreign_key("course_id", "people_training_courses")
        },
        %{"people_training_events_capacity" => check("capacity > 0")}
      ),
      table(
        "sessions",
        %{
          "event_id" => column(:bigint, false),
          "name" => column({:varchar, 160}, false),
          "capacity" => column(:integer, false),
          "time_zone" => column({:varchar, 100}, false),
          "starts_at" => column({:timestamp, 0}, false),
          "ends_at" => column({:timestamp, 0}, false)
        },
        %{
          "people_training_sessions_tenant_id_company_id_starts_at_index" =>
            index(["tenant_id", "company_id", "starts_at"], false)
        },
        %{
          "people_training_sessions_event_scope" =>
            foreign_key("event_id", "people_training_events")
        },
        %{
          "people_training_sessions_capacity" => check("capacity > 0"),
          "people_training_sessions_times" => check("ends_at > starts_at")
        }
      )
    ]
  end

  defp table(suffix, fields, indexes, keys \\ %{}, checks \\ %{}) do
    name = "people_training_" <> suffix

    common = %{
      "id" => %{type: :bigint, nullable: false, default: {:sequence, name <> "_id_seq"}},
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "actor_user_id" => column(:bigint, false),
      "impersonator_id" => column(:bigint, true),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }

    %{
      name: name,
      columns: Map.merge(common, fields),
      indexes: Map.put(indexes, name <> "_pkey", index(["id"], true)),
      foreign_keys: keys,
      checks: checks
    }
  end

  defp column(type, nullable), do: %{type: type, nullable: nullable, default: nil}
  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}

  defp foreign_key(column, target),
    do: %{
      columns: [column, "tenant_id", "company_id"],
      references: {target, ["id", "tenant_id", "company_id"]},
      on_delete: :nothing
    }

  defp check(expression), do: %{expression: expression, validated: true}
end
