defmodule Bilimbi.People.Claims.SchemaContract do
  @moduledoc "Fresh Bilimbi claims schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.
  @currency_check "(currency)::text ~ '^[A-Z]{3}$'::text"

  def migration_version, do: 20_260_930_170_101

  @impl true
  def tables do
    [
      %{
        name: "people_claim_categories",
        columns:
          common_columns("people_claim_categories")
          |> Map.merge(%{
            "code" => column({:varchar, 60}, false),
            "name" => column({:varchar, 120}, false),
            "active" => column(:boolean, false, {:boolean, true})
          }),
        indexes: %{
          "people_claim_categories_pkey" => index(["id"], true),
          "people_claim_categories_company_code_unique" => index(["company_id", "code"], true),
          "people_claim_categories_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_claim_types",
        columns:
          common_columns("people_claim_types")
          |> Map.merge(%{
            "category_id" => column(:bigint, false),
            "code" => column({:varchar, 60}, false),
            "name" => column({:varchar, 120}, false),
            "receipt_requirement" => column({:varchar, 20}, false),
            "eligibility" => column({:varchar, 20}, false, {:string, "all_employees"}),
            "active" => column(:boolean, false, {:boolean, true})
          }),
        indexes: %{
          "people_claim_types_pkey" => index(["id"], true),
          "people_claim_types_company_code_unique" => index(["company_id", "code"], true),
          "people_claim_types_tenant_id_company_id_category_id_index" =>
            index(["tenant_id", "company_id", "category_id"])
        },
        foreign_keys: %{
          "people_claim_types_category_id_fkey" =>
            foreign_key("category_id", "people_claim_categories")
        },
        checks: %{
          "people_claim_types_receipt_requirement_check" =>
            check(
              "(receipt_requirement)::text = ANY ((ARRAY['always'::character varying, " <>
                "'above_threshold'::character varying, 'never'::character varying])::text[])"
            ),
          "people_claim_types_eligibility_check" =>
            check(
              "(eligibility)::text = ANY ((ARRAY['all_employees'::character varying, " <>
                "'assigned_only'::character varying])::text[])"
            )
        }
      },
      %{
        name: "people_claim_policies",
        columns:
          common_columns("people_claim_policies")
          |> Map.merge(%{
            "claim_type_id" => column(:bigint, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true),
            "currency" => column({:varchar, 3}, false),
            "per_claim_limit" => column({:numeric, 14, 2}, true),
            "monthly_limit" => column({:numeric, 14, 2}, true),
            "yearly_limit" => column({:numeric, 14, 2}, true),
            "receipt_threshold" => column({:numeric, 14, 2}, true)
          }),
        indexes: %{
          "people_claim_policies_pkey" => index(["id"], true),
          "people_claim_policies_scope_idx" =>
            index(["tenant_id", "company_id", "claim_type_id", "effective_from"])
        },
        foreign_keys: %{
          "people_claim_policies_claim_type_id_fkey" =>
            foreign_key("claim_type_id", "people_claim_types")
        },
        checks: %{
          "people_claim_policies_period_check" =>
            check("effective_to IS NULL OR effective_to >= effective_from"),
          "people_claim_policies_currency_check" => check(@currency_check),
          "people_claim_policies_amounts_check" =>
            check(
              "(per_claim_limit IS NULL OR per_claim_limit > (0)::numeric) AND " <>
                "(monthly_limit IS NULL OR monthly_limit > (0)::numeric) AND " <>
                "(yearly_limit IS NULL OR yearly_limit > (0)::numeric) AND " <>
                "(receipt_threshold IS NULL OR receipt_threshold >= (0)::numeric)"
            )
        }
      },
      %{
        name: "people_claim_assignments",
        columns:
          common_columns("people_claim_assignments")
          |> Map.merge(%{
            "code" => column({:varchar, 60}, false),
            "name" => column({:varchar, 120}, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true)
          }),
        indexes: %{
          "people_claim_assignments_pkey" => index(["id"], true),
          "people_claim_assignments_company_code_unique" => index(["company_id", "code"], true),
          "people_claim_assignments_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "people_claim_assignments_period_check" =>
            check("effective_to IS NULL OR effective_to >= effective_from")
        }
      },
      %{
        name: "people_claim_assignment_types",
        columns:
          common_columns("people_claim_assignment_types")
          |> Map.merge(%{
            "assignment_id" => column(:bigint, false),
            "claim_type_id" => column(:bigint, false)
          }),
        indexes: %{
          "people_claim_assignment_types_pkey" => index(["id"], true),
          "people_claim_assignment_types_unique" =>
            index(["assignment_id", "claim_type_id"], true),
          "people_claim_assignment_types_scope_idx" =>
            index(["tenant_id", "company_id", "claim_type_id"])
        },
        foreign_keys: %{
          "people_claim_assignment_types_assignment_id_fkey" =>
            foreign_key("assignment_id", "people_claim_assignments"),
          "people_claim_assignment_types_claim_type_id_fkey" =>
            foreign_key("claim_type_id", "people_claim_types")
        }
      },
      %{
        name: "people_claim_assignment_employees",
        columns:
          common_columns("people_claim_assignment_employees")
          |> Map.merge(%{
            "assignment_id" => column(:bigint, false),
            "employee_id" => column(:bigint, false)
          }),
        indexes: %{
          "people_claim_assignment_employees_pkey" => index(["id"], true),
          "people_claim_assignment_employees_unique" =>
            index(["assignment_id", "employee_id"], true),
          "people_claim_assignment_employees_scope_idx" =>
            index(["tenant_id", "company_id", "employee_id"])
        },
        foreign_keys: %{
          "people_claim_assignment_employees_assignment_id_fkey" =>
            foreign_key("assignment_id", "people_claim_assignments")
        }
      },
      %{
        name: "people_claim_handoff_batches",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_claim_handoff_batches_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "currency" => column({:varchar, 3}, false),
          "request_count" => column(:integer, false),
          "total_amount" => column({:numeric, 14, 2}, false),
          "created_by_actor_id" => column(:bigint, false),
          "created_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_claim_handoff_batches_pkey" => index(["id"], true),
          "people_claim_handoff_batches_scope_idx" =>
            index(["tenant_id", "company_id", "created_at"])
        },
        foreign_keys: %{},
        checks: %{
          "people_claim_handoff_batches_currency_check" => check(@currency_check),
          "people_claim_handoff_batches_totals_check" =>
            check("request_count > 0 AND total_amount > (0)::numeric")
        }
      },
      %{
        name: "people_claim_requests",
        columns:
          common_columns("people_claim_requests")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "claim_type_id" => column(:bigint, false),
            "claim_policy_id" => column(:bigint, false),
            "incurred_on" => column(:date, false),
            "amount" => column({:numeric, 14, 2}, false),
            "currency" => column({:varchar, 3}, false),
            "description" => column({:varchar, 500}, true),
            "receipt_number" => column({:varchar, 100}, true),
            "status" => column({:varchar, 20}, false),
            "duplicate_confirmed" => column(:boolean, false, {:boolean, false}),
            "submitted_by_actor_id" => column(:bigint, false),
            "submitted_at" => column({:timestamp, 0}, false),
            "withdrawn_by_actor_id" => column(:bigint, true),
            "withdrawn_at" => column({:timestamp, 0}, true),
            "approved_amount" => column({:numeric, 14, 2}, true),
            "decided_by_actor_id" => column(:bigint, true),
            "decided_at" => column({:timestamp, 0}, true),
            "decision_reason" => column({:varchar, 500}, true),
            "reimbursed_by_actor_id" => column(:bigint, true),
            "reimbursed_at" => column({:timestamp, 0}, true),
            "payment_reference" => column({:varchar, 100}, true),
            "handoff_batch_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_claim_requests_pkey" => index(["id"], true),
          "people_claim_requests_scope_idx" =>
            index(["tenant_id", "company_id", "employee_id", "status"]),
          "people_claim_requests_usage_idx" =>
            index(["company_id", "employee_id", "claim_type_id", "incurred_on"]),
          "people_claim_requests_receipt_unique" => %{
            columns: ["company_id", "employee_id", "receipt_number"],
            unique: true,
            where:
              "receipt_number IS NOT NULL AND " <>
                "((status)::text <> ALL ((ARRAY['withdrawn'::character varying, " <>
                "'rejected'::character varying])::text[]))"
          },
          "people_claim_requests_handoff_batch_id_index" => index(["handoff_batch_id"]),
          "people_claim_requests_queue_idx" =>
            index(["tenant_id", "company_id", "status", "currency"])
        },
        foreign_keys: %{
          "people_claim_requests_claim_type_id_fkey" =>
            foreign_key("claim_type_id", "people_claim_types"),
          "people_claim_requests_claim_policy_id_fkey" =>
            foreign_key("claim_policy_id", "people_claim_policies"),
          "people_claim_requests_handoff_batch_id_fkey" =>
            foreign_key("handoff_batch_id", "people_claim_handoff_batches")
        },
        checks: %{
          "people_claim_requests_status_check" =>
            check(
              "(status)::text = ANY ((ARRAY['submitted'::character varying, " <>
                "'approved'::character varying, 'rejected'::character varying, " <>
                "'reimbursed'::character varying, 'withdrawn'::character varying])::text[])"
            ),
          "people_claim_requests_decision_check" =>
            check(
              "((status)::text = ANY ((ARRAY['submitted'::character varying, " <>
                "'withdrawn'::character varying])::text[]) AND approved_amount IS NULL " <>
                "AND decided_by_actor_id IS NULL AND decided_at IS NULL) OR " <>
                "((status)::text = ANY ((ARRAY['approved'::character varying, " <>
                "'reimbursed'::character varying])::text[]) AND approved_amount > (0)::numeric " <>
                "AND approved_amount <= amount AND decided_by_actor_id IS NOT NULL " <>
                "AND decided_at IS NOT NULL) OR " <>
                "((status)::text = 'rejected'::text AND approved_amount IS NULL " <>
                "AND decided_by_actor_id IS NOT NULL AND decided_at IS NOT NULL " <>
                "AND decision_reason IS NOT NULL)"
            ),
          "people_claim_requests_reimbursement_check" =>
            check(
              "((status)::text = 'reimbursed'::text AND reimbursed_by_actor_id IS NOT NULL " <>
                "AND reimbursed_at IS NOT NULL) OR " <>
                "((status)::text <> 'reimbursed'::text AND reimbursed_by_actor_id IS NULL " <>
                "AND reimbursed_at IS NULL AND payment_reference IS NULL)"
            ),
          "people_claim_requests_handoff_check" =>
            check(
              "handoff_batch_id IS NULL OR ((status)::text = ANY " <>
                "((ARRAY['approved'::character varying, 'reimbursed'::character varying])::text[]))"
            ),
          "people_claim_requests_amount_check" => check("amount > (0)::numeric"),
          "people_claim_requests_currency_check" => check(@currency_check)
        }
      },
      %{
        name: "people_claim_request_events",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_claim_request_events_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "request_id" => column(:bigint, false),
          "from_status" => column({:varchar, 20}, true),
          "to_status" => column({:varchar, 20}, false),
          "actor_id" => column(:bigint, false),
          "reason" => column({:varchar, 500}, true),
          "occurred_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_claim_request_events_pkey" => index(["id"], true),
          "people_claim_request_events_scope_idx" =>
            index(["tenant_id", "company_id", "request_id"])
        },
        foreign_keys: %{
          "people_claim_request_events_request_id_fkey" =>
            foreign_key("request_id", "people_claim_requests")
        }
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

  defp foreign_key(column, table),
    do: %{columns: [column], references: {table, ["id"]}, on_delete: :restrict}

  defp check(expression), do: %{expression: expression, validated: true}
end
