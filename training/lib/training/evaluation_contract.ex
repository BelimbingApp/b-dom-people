defmodule Bilimbi.People.Training.EvaluationContract do
  @moduledoc false
  def tables do
    [
      table(
        "evaluation_policies",
        %{
          "version" => column(:integer),
          "effective_from" => column(:date),
          "effective_to" => column(:date),
          "criteria" => column(:jsonb),
          "effectiveness_criteria" => column(:jsonb),
          "evaluation_days" => column(:integer),
          "checkpoints" => column(:jsonb),
          "reminder_days" => column(:integer),
          "reason" => column(:text)
        },
        %{
          "people_training_evaluation_policy_version" => index(~w(company_id version)),
          "people_training_evaluation_policy_scope" => index(~w(id tenant_id company_id))
        },
        %{},
        %{
          "people_training_evaluation_policy_values" => %{
            expression:
              "(version > 0) AND (effective_to >= effective_from) AND (evaluation_days >= 0) AND (reminder_days >= 0) AND (jsonb_array_length((criteria -> 'items'::text)) > 0) AND (jsonb_array_length((effectiveness_criteria -> 'items'::text)) > 0) AND (jsonb_array_length((checkpoints -> 'days'::text)) > 0) AND (length(btrim(reason)) > 0)",
            validated: true
          }
        }
      ),
      table(
        "evaluation_reviews",
        %{
          "policy_id" => column(:bigint),
          "fact_id" => column(:bigint),
          "kind" => column(:text),
          "checkpoint_days" => column(:integer),
          "due_on" => column(:date)
        },
        %{
          "people_training_evaluation_review_once" => index(~w(fact_id kind checkpoint_days)),
          "people_training_evaluation_review_scope" => index(~w(id tenant_id company_id))
        },
        %{
          "people_training_evaluation_reviews_policy_id_scope" =>
            fk("policy_id", "evaluation_policies"),
          "people_training_evaluation_reviews_fact_id_scope" =>
            fk("fact_id", "participation_facts")
        },
        %{
          "people_training_evaluation_review_kind" => %{
            expression:
              "((kind = 'evaluation'::text) AND (checkpoint_days = 0)) OR ((kind = 'effectiveness'::text) AND (checkpoint_days > 0))",
            validated: true
          }
        }
      ),
      table(
        "evaluation_answers",
        %{"review_id" => column(:bigint), "values" => column(:jsonb), "reason" => column(:text)},
        %{"people_training_evaluation_answer_once" => index(~w(review_id))},
        %{
          "people_training_evaluation_answers_review_id_scope" =>
            fk("review_id", "evaluation_reviews")
        },
        %{
          "people_training_evaluation_answer_reason" => %{
            expression: "length(btrim(reason)) > 0",
            validated: true
          }
        }
      ),
      table(
        "evaluation_reminders",
        %{
          "review_id" => column(:bigint),
          "recipient_employee_id" => column(:bigint),
          "available_on" => column(:date)
        },
        %{"people_training_evaluation_reminder_once" => index(~w(review_id))},
        %{
          "people_training_evaluation_reminders_review_id_scope" =>
            fk("review_id", "evaluation_reviews")
        }
      ),
      table(
        "effectiveness_summaries",
        %{
          "period_start" => column(:date),
          "period_end" => column(:date),
          "minimum_cohort" => column(:integer),
          "status" => column(:text),
          "groups" => column(:jsonb)
        },
        %{
          "people_training_effectiveness_summary_period" =>
            index(~w(tenant_id company_id period_start))
        },
        %{},
        %{
          "people_training_effectiveness_summary_values" => %{
            expression:
              "(period_end >= period_start) AND (minimum_cohort >= 2) AND (status = ANY (ARRAY['current'::text, 'suppressed'::text])) AND (jsonb_typeof((groups -> 'items'::text)) = 'array'::text)",
            validated: true
          }
        }
      )
    ]
  end

  defp table(suffix, fields, indexes, keys, checks \\ %{}) do
    name = "people_training_" <> suffix

    %{
      name: name,
      columns:
        Map.merge(
          %{
            "id" => %{type: :bigint, nullable: false, default: {:sequence, name <> "_id_seq"}},
            "tenant_id" => column(:bigint),
            "company_id" => column(:bigint),
            "actor_user_id" => column(:bigint),
            "impersonator_id" => %{type: :bigint, nullable: true, default: nil},
            "inserted_at" => column({:timestamp, 0}),
            "updated_at" => column({:timestamp, 0})
          },
          fields
        ),
      indexes: Map.put(indexes, name <> "_pkey", index(~w(id))),
      foreign_keys: keys,
      checks: checks
    }
  end

  defp column(type), do: %{type: type, nullable: false, default: nil}
  defp index(columns), do: %{columns: columns, unique: true, where: nil}

  defp fk(column, target),
    do: %{
      columns: [column, "tenant_id", "company_id"],
      references: {"people_training_" <> target, ~w(id tenant_id company_id)},
      on_delete: :nothing
    }
end
