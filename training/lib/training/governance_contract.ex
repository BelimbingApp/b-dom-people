defmodule Bilimbi.People.Training.GovernanceContract do
  @moduledoc false
  def tables do
    [
      %{
        name: "people_training_budget_policies",
        columns:
          Map.merge(common("people_training_budget_policies"), %{
            "currency" => column(:text, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, false),
            "amount" => column({:numeric, 18, 4}, false),
            "reason" => column(:text, false)
          }),
        indexes: %{
          "people_training_budget_policies_pkey" => index(["id"], true),
          "people_training_budget_policies_id_tenant_id_company_id_index" =>
            index(["id", "tenant_id", "company_id"], true)
        },
        foreign_keys: %{},
        checks: %{
          "people_training_budget_policies_dates" => %{
            expression: "effective_to >= effective_from",
            validated: true
          },
          "people_training_budget_policies_amount" => %{
            expression: "amount >= (0)::numeric",
            validated: true
          }
        }
      },
      %{
        name: "people_training_requests",
        columns:
          Map.merge(common("people_training_requests"), %{
            "employee_id" => column(:bigint, false),
            "course_id" => column(:bigint, true),
            "need" => column(:text, false),
            "objective" => column(:text, false),
            "expected_result" => column(:text, false),
            "proposed_on" => column(:date, false),
            "estimated_cost" => column({:numeric, 18, 4}, false),
            "currency" => column(:text, false),
            "status" => column(:text, false),
            "budget_policy_id" => column(:bigint, true),
            "approved_cost" => column({:numeric, 18, 4}, true)
          }),
        indexes: %{
          "people_training_requests_pkey" => index(["id"], true),
          "people_training_requests_id_tenant_id_company_id_index" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_training_requests_tenant_id_company_id_employee_id_index" =>
            index(["tenant_id", "company_id", "employee_id"], false)
        },
        foreign_keys: %{
          "people_training_requests_course_id_scope" =>
            fk("course_id", "people_training_courses"),
          "people_training_requests_budget_policy_id_scope" =>
            fk("budget_policy_id", "people_training_budget_policies")
        },
        checks: %{
          "people_training_requests_status" => %{
            expression:
              "status = ANY (ARRAY['draft'::text, 'pending_hod'::text, 'pending_hr'::text, 'pending_approval'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text])",
            validated: true
          },
          "people_training_requests_cost" => %{
            expression:
              "(estimated_cost >= (0)::numeric) AND ((approved_cost IS NULL) OR (approved_cost >= (0)::numeric))",
            validated: true
          },
          "people_training_requests_approval" => %{
            expression:
              "((status = 'approved'::text) AND (budget_policy_id IS NOT NULL) AND (approved_cost IS NOT NULL)) OR ((status <> 'approved'::text) AND (budget_policy_id IS NULL) AND (approved_cost IS NULL))",
            validated: true
          }
        }
      },
      %{
        name: "people_training_plans",
        columns:
          Map.merge(common("people_training_plans"), %{
            "plan_key" => column(:text, false),
            "version" => column(:integer, false),
            "manager_employee_id" => column(:bigint, false),
            "period_start" => column(:date, false),
            "period_end" => column(:date, false),
            "objectives" => column(:text, false),
            "status" => column(:text, false),
            "prior_plan_id" => column(:bigint, true),
            "reason" => column(:text, false)
          }),
        indexes: %{
          "people_training_plans_pkey" => index(["id"], true),
          "people_training_plans_id_tenant_id_company_id_index" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_training_plans_company_id_plan_key_version_index" =>
            index(["company_id", "plan_key", "version"], true)
        },
        foreign_keys: %{
          "people_training_plans_prior_plan_id_scope" =>
            fk("prior_plan_id", "people_training_plans")
        },
        checks: %{
          "people_training_plans_status" => %{
            expression:
              "status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text, 'superseded'::text])",
            validated: true
          },
          "people_training_plans_dates" => %{
            expression: "period_end >= period_start",
            validated: true
          },
          "people_training_plans_version" => %{expression: "version > 0", validated: true}
        }
      },
      %{
        name: "people_training_plan_items",
        columns:
          Map.merge(common("people_training_plan_items"), %{
            "plan_id" => column(:bigint, false),
            "request_id" => column(:bigint, true),
            "need" => column(:text, false),
            "expected_result" => column(:text, false),
            "target_cohort" => column(:text, false),
            "responsible_owner" => column(:text, false),
            "intended_timing" => column(:text, false),
            "evaluation_approach" => column(:text, false)
          }),
        indexes: %{
          "people_training_plan_items_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "people_training_plan_items_plan_id_scope" => fk("plan_id", "people_training_plans"),
          "people_training_plan_items_request_id_scope" =>
            fk("request_id", "people_training_requests")
        },
        checks: %{}
      },
      %{
        name: "people_training_request_decisions",
        columns:
          Map.merge(common("people_training_request_decisions"), %{
            "request_id" => column(:bigint, false),
            "action" => column(:text, false),
            "from_status" => column(:text, false),
            "to_status" => column(:text, false),
            "reason" => column(:text, false)
          }),
        indexes: %{
          "people_training_request_decisions_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "people_training_request_decisions_request_id_scope" =>
            fk("request_id", "people_training_requests")
        },
        checks: %{}
      },
      %{
        name: "people_training_plan_decisions",
        columns:
          Map.merge(common("people_training_plan_decisions"), %{
            "plan_id" => column(:bigint, false),
            "action" => column(:text, false),
            "from_status" => column(:text, false),
            "to_status" => column(:text, false),
            "reason" => column(:text, false)
          }),
        indexes: %{
          "people_training_plan_decisions_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "people_training_plan_decisions_plan_id_scope" => fk("plan_id", "people_training_plans")
        },
        checks: %{}
      }
    ]
  end

  defp common(name) do
    %{
      "id" => %{type: :bigint, nullable: false, default: {:sequence, name <> "_id_seq"}},
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "actor_user_id" => column(:bigint, false),
      "impersonator_id" => column(:bigint, true),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }
  end

  defp column(type, nullable), do: %{type: type, nullable: nullable, default: nil}
  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}

  defp fk(column, target),
    do: %{
      columns: [column, "tenant_id", "company_id"],
      references: {target, ["id", "tenant_id", "company_id"]},
      on_delete: :nothing
    }
end
