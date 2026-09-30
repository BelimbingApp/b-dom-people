defmodule Bilimbi.People.Progression.SchemaContract do
  @moduledoc "Fresh Bilimbi progression schema; verify after migration."
  @behaviour Bilimbi.Base.Database.SchemaContract
  @impl true
  def tables do
    [
      %{
        name: "people_progression_policy_versions",
        columns: %{
          "id" =>
            column(:bigint, false, {:sequence, "people_progression_policy_versions_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "code" => column(:text, false),
          "version" => column(:integer, false),
          "name" => column(:text, false),
          "effective_from" => column(:date, false),
          "rules" => column(:jsonb, false),
          "status" => column(:text, false),
          "actor_user_id" => column(:bigint, false),
          "published_by_user_id" => column(:bigint, true),
          "published_at" => column({:timestamp, 0}, true),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_progression_policy_versions_pkey" => index(["id"], true),
          "people_progression_policy_identity" => index(["company_id", "code", "version"], true),
          "people_progression_policy_scope" => index(["tenant_id", "company_id"], false)
        },
        foreign_keys: %{},
        checks: %{
          "people_progression_policy_content" => %{
            expression:
              "((version > 0) AND (length(btrim(code)) > 0) AND (length(btrim(name)) > 0) AND (jsonb_typeof(rules) = 'object'::text))"
          },
          "people_progression_policy_workflow" => %{
            expression:
              "(((status = 'draft'::text) AND (published_at IS NULL) AND (published_by_user_id IS NULL)) OR ((status = 'published'::text) AND (published_at IS NOT NULL) AND (published_by_user_id IS NOT NULL)))"
          }
        }
      }
    ]
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}
end
