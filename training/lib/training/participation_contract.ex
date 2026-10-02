defmodule Bilimbi.People.Training.ParticipationContract do
  @moduledoc false
  def tables do
    [
      table(
        "participation_facts",
        %{
          "session_id" => col(:bigint),
          "employee_id" => col(:bigint),
          "revision" => col(:integer),
          "status" => col({:varchar, 20}),
          "reason" => col(:text),
          "import_key" => col({:varchar, 160})
        },
        %{
          "people_training_participation_facts_import" =>
            index(["tenant_id", "company_id", "import_key"], true),
          "people_training_participation_facts_revision" =>
            index(["session_id", "employee_id", "revision"], true),
          "people_training_facts_scope" => index(["id", "tenant_id", "company_id"], true)
        },
        %{
          "people_training_participation_facts_session_scope" =>
            fk("session_id", "people_training_sessions")
        },
        %{
          "people_training_participation_facts_values" => %{
            validated: true,
            expression:
              "(revision > 0) AND (employee_id > 0) AND ((status)::text = ANY ((ARRAY['confirmed'::character varying, 'absent'::character varying])::text[])) AND (length(btrim(reason)) > 0) AND (length(btrim((import_key)::text)) > 0)"
          }
        }
      ),
      table(
        "evidence",
        %{"fact_id" => col(:bigint), "artifact_id" => col(:uuid)},
        %{
          "people_training_evidence_artifact_id_index" => index(["artifact_id"], true),
          "people_training_evidence_tenant_id_company_id_fact_id_index" =>
            index(["tenant_id", "company_id", "fact_id"], false)
        },
        %{
          "people_training_evidence_fact_scope" =>
            fk("fact_id", "people_training_participation_facts")
        },
        %{}
      )
    ]
  end

  defp table(suffix, fields, indexes, keys, checks) do
    name = "people_training_" <> suffix

    %{
      name: name,
      columns:
        Map.merge(
          %{
            "id" => %{type: :bigint, nullable: false, default: {:sequence, name <> "_id_seq"}},
            "tenant_id" => col(:bigint),
            "company_id" => col(:bigint),
            "actor_user_id" => col(:bigint),
            "impersonator_id" => %{type: :bigint, nullable: true, default: nil},
            "inserted_at" => col({:timestamp, 0}),
            "updated_at" => col({:timestamp, 0})
          },
          fields
        ),
      indexes: Map.put(indexes, name <> "_pkey", index(["id"], true)),
      foreign_keys: keys,
      checks: checks
    }
  end

  defp col(type), do: %{type: type, nullable: false, default: nil}
  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}

  defp fk(column, target),
    do: %{
      columns: [column, "tenant_id", "company_id"],
      references: {target, ["id", "tenant_id", "company_id"]},
      on_delete: :nothing
    }
end
