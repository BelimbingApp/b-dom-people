defmodule Bilimbi.People.Skills.SchemaContract do
  @moduledoc "Fresh Bilimbi skills catalog, scale and requirement profile schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.
  @status_check "(status)::text = ANY ((ARRAY['draft'::character varying, " <>
                  "'published'::character varying, 'retired'::character varying])::text[])"

  def migration_version, do: 20_260_930_220_137

  @impl true
  def tables, do: catalog_tables() ++ assessment_tables()

  defp catalog_tables do
    [
      %{
        name: "people_skill_categories",
        columns:
          common("people_skill_categories")
          |> Map.merge(%{
            "code" => column({:varchar, 80}, false),
            "name" => column({:varchar, 160}, false),
            "description" => column({:varchar, 2000}, true),
            "active" => column(:boolean, false)
          }),
        indexes: %{
          "people_skill_categories_pkey" => index(["id"], true),
          "people_skill_categories_company_code_unique" => index(["company_id", "code"], true),
          "people_skill_categories_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_skills",
        columns:
          common("people_skills")
          |> Map.merge(%{
            "category_id" => column(:bigint, false),
            "code" => column({:varchar, 80}, false),
            "name" => column({:varchar, 160}, false),
            "definition" => column({:varchar, 2000}, false),
            "evidence_guide" => column({:varchar, 2000}, true),
            "critical" => column(:boolean, false),
            "reassessment_months" => column(:integer, true),
            "active" => column(:boolean, false)
          }),
        indexes: %{
          "people_skills_pkey" => index(["id"], true),
          "people_skills_company_code_unique" => index(["company_id", "code"], true),
          "people_skills_tenant_id_company_id_category_id_index" =>
            index(["tenant_id", "company_id", "category_id"])
        },
        foreign_keys: %{
          "people_skills_category_id_fkey" =>
            foreign_key("category_id", "people_skill_categories")
        },
        checks: %{
          "people_skills_reassessment_months_range" =>
            check(
              "reassessment_months IS NULL OR " <>
                "(reassessment_months >= 1 AND reassessment_months <= 120)"
            )
        }
      },
      %{
        name: "people_skill_scales",
        columns: versioned("people_skill_scales"),
        indexes: versioned_indexes("people_skill_scales"),
        foreign_keys: %{},
        checks: %{"people_skill_scales_status" => check(@status_check)}
      },
      %{
        name: "people_skill_scale_levels",
        columns:
          common("people_skill_scale_levels")
          |> Map.merge(%{
            "scale_id" => column(:bigint, false),
            "level" => column(:integer, false),
            "name" => column({:varchar, 100}, false),
            "anchor" => column({:varchar, 2000}, false),
            "authority" => column({:varchar, 2000}, false)
          }),
        indexes: %{
          "people_skill_scale_levels_pkey" => index(["id"], true),
          "people_skill_scale_levels_scale_level_unique" => index(["scale_id", "level"], true)
        },
        foreign_keys: %{
          "people_skill_scale_levels_scale_id_fkey" =>
            foreign_key("scale_id", "people_skill_scales")
        },
        checks: %{
          "people_skill_scale_levels_level_range" => check("level >= 0 AND level <= 20")
        }
      },
      %{
        name: "people_skill_profiles",
        columns:
          versioned("people_skill_profiles")
          |> Map.merge(%{
            "scale_id" => column(:bigint, false),
            "effective_from" => column(:date, true),
            "effective_to" => column(:date, true)
          }),
        indexes: versioned_indexes("people_skill_profiles"),
        foreign_keys: %{
          "people_skill_profiles_scale_id_fkey" => foreign_key("scale_id", "people_skill_scales")
        },
        checks: %{
          "people_skill_profiles_status" => check(@status_check),
          "people_skill_profiles_effective_range" =>
            check("effective_to IS NULL OR effective_to >= effective_from"),
          "people_skill_profiles_published_dated" =>
            check("(status)::text = 'draft'::text OR effective_from IS NOT NULL")
        }
      },
      %{
        name: "people_skill_profile_items",
        columns:
          common("people_skill_profile_items")
          |> Map.merge(%{
            "profile_id" => column(:bigint, false),
            "skill_id" => column(:bigint, false),
            "sequence" => column(:integer, false),
            "required_level" => column(:integer, false),
            "criticality" => column({:varchar, 16}, false),
            "weight_percent" => column({:numeric, 5, 2}, false),
            "mandatory" => column(:boolean, false),
            "evidence_standard" => column({:varchar, 2000}, true)
          }),
        indexes: %{
          "people_skill_profile_items_pkey" => index(["id"], true),
          "people_skill_profile_items_profile_skill_unique" =>
            index(["profile_id", "skill_id"], true),
          "people_skill_profile_items_profile_sequence_unique" =>
            index(["profile_id", "sequence"], true)
        },
        foreign_keys: %{
          "people_skill_profile_items_profile_id_fkey" =>
            foreign_key("profile_id", "people_skill_profiles"),
          "people_skill_profile_items_skill_id_fkey" => foreign_key("skill_id", "people_skills")
        },
        checks: %{
          "people_skill_profile_items_criticality" =>
            check(
              "(criticality)::text = ANY ((ARRAY['critical'::character varying, " <>
                "'essential'::character varying, 'development'::character varying])::text[])"
            ),
          "people_skill_profile_items_weight_range" =>
            check("weight_percent >= (0)::numeric AND weight_percent <= (100)::numeric")
        }
      },
      %{
        name: "people_skill_profile_selectors",
        columns:
          common("people_skill_profile_selectors")
          |> Map.merge(%{
            "profile_id" => column(:bigint, false),
            "selector_type" => column({:varchar, 16}, false),
            "position_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_skill_profile_selectors_pkey" => index(["id"], true),
          "people_skill_profile_selectors_unique" =>
            index(["profile_id", "selector_type", "position_id"], true)
        },
        foreign_keys: %{
          "people_skill_profile_selectors_profile_id_fkey" =>
            foreign_key("profile_id", "people_skill_profiles")
        },
        checks: %{
          "people_skill_profile_selectors_target" =>
            check(
              "((selector_type)::text = 'company'::text AND position_id IS NULL) OR " <>
                "((selector_type)::text = 'position'::text AND position_id IS NOT NULL)"
            )
        }
      }
    ]
  end

  @criticality "(criticality)::text = ANY ((ARRAY['critical'::character varying, " <>
                 "'essential'::character varying, 'development'::character varying])::text[])"

  defp assessment_tables do
    [
      %{
        name: "people_skill_assessments",
        columns:
          common("people_skill_assessments")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "skill_id" => column(:bigint, false),
            "profile_id" => column(:bigint, false),
            "scale_id" => column(:bigint, false),
            "required_level" => column(:integer, false),
            "criticality" => column({:varchar, 16}, false),
            "weight_percent" => column({:numeric, 5, 2}, false),
            "mandatory" => column(:boolean, false),
            "assessed_level" => column(:integer, false),
            "gap" => column(:integer, false),
            "priority_multiplier" => column(:integer, false),
            "priority_score" => column(:integer, false),
            "result_band" => column({:varchar, 16}, false),
            "method" => column({:varchar, 80}, true),
            "evidence" => column({:varchar, 4000}, false),
            "notes" => column({:varchar, 2000}, true),
            "assessed_on" => column(:date, false),
            "valid_until" => column(:date, true),
            "next_due_on" => column(:date, false),
            "status" => column({:varchar, 16}, false),
            "assessor_user_id" => column(:bigint, false),
            "reviewed_by_user_id" => column(:bigint, true),
            "reviewed_at" => column({:timestamp, 0}, true),
            "review_note" => column({:varchar, 2000}, true),
            "finalized_by_user_id" => column(:bigint, true),
            "finalized_at" => column({:timestamp, 0}, true),
            "supersedes_assessment_id" => column(:bigint, true),
            "request_key" => column({:varchar, 80}, false)
          }),
        indexes: %{
          "people_skill_assessments_pkey" => index(["id"], true),
          "people_skill_assessments_subject_unique" =>
            index(["id", "company_id", "employee_id", "skill_id"], true),
          "people_skill_assessments_request_key_unique" =>
            index(["company_id", "assessor_user_id", "request_key"], true),
          "people_skill_assessments_one_successor" =>
            index(["supersedes_assessment_id"], true, "supersedes_assessment_id IS NOT NULL"),
          "people_skill_assessments_subject_status_index" =>
            index(["company_id", "employee_id", "skill_id", "status"]),
          "people_skill_assessments_tenant_id_company_id_status_index" =>
            index(["tenant_id", "company_id", "status"])
        },
        foreign_keys: %{
          "people_skill_assessments_skill_id_fkey" => foreign_key("skill_id", "people_skills"),
          "people_skill_assessments_profile_id_fkey" =>
            foreign_key("profile_id", "people_skill_profiles"),
          "people_skill_assessments_scale_id_fkey" =>
            foreign_key("scale_id", "people_skill_scales"),
          "people_skill_assessments_supersedes_assessment_id_fkey" =>
            foreign_key("supersedes_assessment_id", "people_skill_assessments")
        },
        checks: %{
          "people_skill_assessments_status" =>
            check(
              "(status)::text = ANY ((ARRAY['pending_review'::character varying, " <>
                "'verified'::character varying, 'returned'::character varying, " <>
                "'finalized'::character varying])::text[])"
            ),
          "people_skill_assessments_criticality" => check(@criticality),
          "people_skill_assessments_band" =>
            check(
              "(result_band)::text = ANY ((ARRAY['exceeds'::character varying, " <>
                "'meets'::character varying, 'minor_gap'::character varying, " <>
                "'major_gap'::character varying, 'critical_gap'::character varying])::text[])"
            ),
          "people_skill_assessments_levels" =>
            check(
              "required_level >= 0 AND required_level <= 20 AND assessed_level >= 0 AND " <>
                "assessed_level <= 20 AND gap = GREATEST(required_level - assessed_level, 0) " <>
                "AND priority_multiplier >= 0 AND priority_score = gap * priority_multiplier"
            ),
          "people_skill_assessments_evidence" => check("length(btrim((evidence)::text)) > 0"),
          "people_skill_assessments_dates" =>
            check("valid_until IS NULL OR valid_until >= assessed_on"),
          "people_skill_assessments_workflow" =>
            check(
              "((status)::text = 'pending_review'::text AND reviewed_at IS NULL AND " <>
                "finalized_at IS NULL) OR ((status)::text = 'verified'::text AND " <>
                "reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " <>
                "finalized_at IS NULL) OR ((status)::text = 'returned'::text AND " <>
                "reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " <>
                "review_note IS NOT NULL AND finalized_at IS NULL) OR " <>
                "((status)::text = 'finalized'::text AND reviewed_at IS NOT NULL AND " <>
                "reviewed_by_user_id IS NOT NULL AND finalized_at IS NOT NULL AND " <>
                "finalized_by_user_id IS NOT NULL)"
            ),
          "people_skill_assessments_independent" =>
            check(
              "(reviewed_by_user_id IS NULL OR reviewed_by_user_id <> assessor_user_id) AND " <>
                "(finalized_by_user_id IS NULL OR finalized_by_user_id <> assessor_user_id)"
            )
        }
      },
      %{
        name: "people_skill_assessment_decisions",
        columns:
          append_only("people_skill_assessment_decisions")
          |> Map.merge(%{
            "assessment_id" => column(:bigint, false),
            "decision" => column({:varchar, 16}, false),
            "actor_user_id" => column(:bigint, false),
            "note" => column({:varchar, 2000}, true)
          }),
        indexes: %{
          "people_skill_assessment_decisions_pkey" => index(["id"], true),
          "people_skill_assessment_decisions_once" => index(["assessment_id", "decision"], true),
          "people_skill_assessment_decisions_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "people_skill_assessment_decisions_assessment_id_fkey" =>
            foreign_key("assessment_id", "people_skill_assessments")
        },
        checks: %{
          "people_skill_assessment_decisions_decision" =>
            check(
              "(decision)::text = ANY ((ARRAY['submitted'::character varying, " <>
                "'verified'::character varying, 'returned'::character varying, " <>
                "'finalized'::character varying])::text[])"
            )
        }
      },
      %{
        name: "people_skill_scores",
        columns:
          common("people_skill_scores")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "skill_id" => column(:bigint, false),
            "assessment_id" => column(:bigint, false),
            "profile_id" => column(:bigint, false),
            "required_level" => column(:integer, false),
            "current_level" => column(:integer, false),
            "gap" => column(:integer, false),
            "criticality" => column({:varchar, 16}, false),
            "mandatory" => column(:boolean, false),
            "priority_score" => column(:integer, false),
            "assessed_on" => column(:date, false),
            "valid_until" => column(:date, true),
            "next_due_on" => column(:date, false)
          }),
        indexes: %{
          "people_skill_scores_pkey" => index(["id"], true),
          "people_skill_scores_subject_unique" =>
            index(["company_id", "employee_id", "skill_id"], true),
          "people_skill_scores_tenant_id_company_id_index" => index(["tenant_id", "company_id"]),
          "people_skill_scores_company_id_next_due_on_index" =>
            index(["company_id", "next_due_on"])
        },
        foreign_keys: %{
          "people_skill_scores_assessment_fkey" => %{
            columns: ["assessment_id", "company_id", "employee_id", "skill_id"],
            references:
              {"people_skill_assessments", ["id", "company_id", "employee_id", "skill_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_skill_scores_gap" => check("gap = GREATEST(required_level - current_level, 0)")
        }
      },
      %{
        name: "people_skill_reassessment_requests",
        columns:
          common("people_skill_reassessment_requests")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "skill_id" => column(:bigint, false),
            "reason" => column({:varchar, 1000}, false),
            "requested_by_user_id" => column(:bigint, false),
            "due_on" => column(:date, false),
            "status" => column({:varchar, 12}, false),
            "performed_by_user_id" => column(:bigint, true),
            "performed_at" => column({:timestamp, 0}, true),
            "assessment_id" => column(:bigint, true),
            "cancelled_by_user_id" => column(:bigint, true),
            "cancelled_at" => column({:timestamp, 0}, true)
          }),
        indexes: %{
          "people_skill_reassessment_requests_pkey" => index(["id"], true),
          "people_skill_reassessment_requests_one_open" =>
            index(
              ["company_id", "employee_id", "skill_id"],
              true,
              "(status)::text = 'pending'::text"
            ),
          "people_skill_reassessment_requests_status_index" =>
            index(["tenant_id", "company_id", "status"])
        },
        foreign_keys: %{
          "people_skill_reassessment_requests_skill_id_fkey" =>
            foreign_key("skill_id", "people_skills"),
          "people_skill_reassessment_requests_assessment_id_fkey" =>
            foreign_key("assessment_id", "people_skill_assessments")
        },
        checks: %{
          "people_skill_reassessment_requests_state" =>
            check(
              "((status)::text = 'pending'::text AND performed_at IS NULL AND " <>
                "cancelled_at IS NULL) OR ((status)::text = 'performed'::text AND " <>
                "performed_at IS NOT NULL AND performed_by_user_id IS NOT NULL AND " <>
                "assessment_id IS NOT NULL AND cancelled_at IS NULL) OR " <>
                "((status)::text = 'cancelled'::text AND cancelled_at IS NOT NULL AND " <>
                "cancelled_by_user_id IS NOT NULL AND performed_at IS NULL)"
            )
        }
      },
      %{
        name: "people_skill_action_types",
        columns:
          common("people_skill_action_types")
          |> Map.merge(%{
            "code" => column({:varchar, 80}, false),
            "name" => column({:varchar, 160}, false),
            "requires_provider" => column(:boolean, false),
            "active" => column(:boolean, false)
          }),
        indexes: %{
          "people_skill_action_types_pkey" => index(["id"], true),
          "people_skill_action_types_company_code_unique" => index(["company_id", "code"], true),
          "people_skill_action_types_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_skill_actions",
        columns:
          common("people_skill_actions")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "employee_name" => column({:varchar, 200}, false),
            "skill_id" => column(:bigint, false),
            "source_assessment_id" => column(:bigint, true),
            "action_type_id" => column(:bigint, false),
            "starting_level" => column(:integer, false),
            "target_level" => column(:integer, false),
            "gap_at_start" => column(:integer, false),
            "criticality" => column({:varchar, 16}, false),
            "mandatory" => column(:boolean, false),
            "priority_multiplier" => column(:integer, false),
            "priority_score" => column(:integer, false),
            "priority_explanation" => column({:varchar, 300}, false),
            "manual_reason" => column({:varchar, 1000}, true),
            "objective" => column({:varchar, 2000}, false),
            "intervention" => column({:varchar, 2000}, false),
            "expected_evidence" => column({:varchar, 2000}, false),
            "owner_employee_id" => column(:bigint, false),
            "coordinator_employee_id" => column(:bigint, false),
            "provider_employee_id" => column(:bigint, true),
            "provider_name" => column({:varchar, 160}, true),
            "start_on" => column(:date, false),
            "due_on" => column(:date, false),
            "status" => column({:varchar, 24}, false),
            "closure" => column({:varchar, 24}, false),
            "approved_by_user_id" => column(:bigint, true),
            "approved_at" => column({:timestamp, 0}, true),
            "completed_at" => column({:timestamp, 0}, true),
            "completion_evidence" => column({:varchar, 2000}, true),
            "reassessment_due_on" => column(:date, true),
            "post_assessment_id" => column(:bigint, true),
            "post_level" => column(:integer, true),
            "improvement" => column(:integer, true),
            "next_steps" => column({:varchar, 2000}, true),
            "created_by_user_id" => column(:bigint, false),
            "request_key" => column({:varchar, 80}, false)
          }),
        indexes: %{
          "people_skill_actions_pkey" => index(["id"], true),
          "people_skill_actions_request_key_unique" => index(["company_id", "request_key"], true),
          "people_skill_actions_one_per_assessment" =>
            index(["source_assessment_id"], true, "source_assessment_id IS NOT NULL"),
          "people_skill_actions_tenant_id_company_id_status_due_on_index" =>
            index(["tenant_id", "company_id", "status", "due_on"]),
          "people_skill_actions_company_id_employee_id_skill_id_index" =>
            index(["company_id", "employee_id", "skill_id"])
        },
        foreign_keys: %{
          "people_skill_actions_skill_id_fkey" => foreign_key("skill_id", "people_skills"),
          "people_skill_actions_source_assessment_id_fkey" =>
            foreign_key("source_assessment_id", "people_skill_assessments"),
          "people_skill_actions_action_type_id_fkey" =>
            foreign_key("action_type_id", "people_skill_action_types"),
          "people_skill_actions_post_assessment_id_fkey" =>
            foreign_key("post_assessment_id", "people_skill_assessments")
        },
        checks: %{
          "people_skill_actions_status" =>
            check(
              "(status)::text = ANY ((ARRAY['proposed'::character varying, " <>
                "'scheduled'::character varying, 'not_started'::character varying, " <>
                "'in_progress'::character varying, 'on_hold'::character varying, " <>
                "'pending_reassessment'::character varying, 'completed'::character varying, " <>
                "'cancelled'::character varying])::text[])"
            ),
          "people_skill_actions_closure" =>
            check(
              "(closure)::text = ANY ((ARRAY['open'::character varying, " <>
                "'pending_reassessment'::character varying, " <>
                "'closed_competent'::character varying, " <>
                "'further_action_required'::character varying, " <>
                "'cancelled'::character varying])::text[])"
            ),
          "people_skill_actions_criticality" => check(@criticality),
          "people_skill_actions_levels" =>
            check(
              "starting_level >= 0 AND starting_level <= 20 AND target_level >= 0 AND " <>
                "target_level <= 20 AND gap_at_start = GREATEST(target_level - starting_level, 0) " <>
                "AND priority_multiplier >= 0 AND priority_score = gap_at_start * priority_multiplier"
            ),
          "people_skill_actions_dates" => check("due_on >= start_on"),
          "people_skill_actions_basis" =>
            check("source_assessment_id IS NOT NULL OR manual_reason IS NOT NULL"),
          "people_skill_actions_terminal" =>
            check(
              "((status)::text = 'completed'::text AND (closure)::text = ANY " <>
                "((ARRAY['closed_competent'::character varying, " <>
                "'further_action_required'::character varying])::text[]) AND " <>
                "post_assessment_id IS NOT NULL) OR ((status)::text = 'cancelled'::text AND " <>
                "(closure)::text = 'cancelled'::text) OR " <>
                "((status)::text = 'pending_reassessment'::text AND " <>
                "(closure)::text = 'pending_reassessment'::text AND completed_at IS NOT NULL) OR " <>
                "((status)::text <> ALL ((ARRAY['completed'::character varying, " <>
                "'cancelled'::character varying, " <>
                "'pending_reassessment'::character varying])::text[]) AND " <>
                "(closure)::text = 'open'::text)"
            )
        }
      },
      %{
        name: "people_skill_action_events",
        columns:
          append_only("people_skill_action_events")
          |> Map.merge(%{
            "action_id" => column(:bigint, false),
            "event_type" => column({:varchar, 32}, false),
            "from_status" => column({:varchar, 24}, true),
            "to_status" => column({:varchar, 24}, true),
            "comment" => column({:varchar, 2000}, true),
            "evidence" => column({:varchar, 2000}, true),
            "actor_user_id" => column(:bigint, false)
          }),
        indexes: %{
          "people_skill_action_events_pkey" => index(["id"], true),
          "people_skill_action_events_action_id_inserted_at_index" =>
            index(["action_id", "inserted_at"]),
          "people_skill_action_events_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "people_skill_action_events_action_id_fkey" =>
            foreign_key("action_id", "people_skill_actions")
        }
      },
      %{
        name: "people_skill_reminders",
        columns:
          common("people_skill_reminders")
          |> Map.merge(%{
            "rule" => column({:varchar, 24}, false),
            "employee_id" => column(:bigint, true),
            "skill_id" => column(:bigint, false),
            "action_id" => column(:bigint, true),
            "period_key" => column({:varchar, 12}, false),
            "recipient_user_id" => column(:bigint, false),
            "due_on" => column(:date, false),
            "state" => column({:varchar, 12}, false),
            "failure" => column({:varchar, 300}, true),
            "sent_at" => column({:timestamp, 0}, true)
          }),
        indexes: %{
          "people_skill_reminders_pkey" => index(["id"], true),
          "people_skill_reminders_once" =>
            index(
              [
                "company_id",
                "rule",
                "employee_id",
                "skill_id",
                "action_id",
                "period_key",
                "recipient_user_id"
              ],
              true
            ),
          "people_skill_reminders_recipient_index" =>
            index(["tenant_id", "company_id", "recipient_user_id"])
        },
        foreign_keys: %{
          "people_skill_reminders_skill_id_fkey" => foreign_key("skill_id", "people_skills"),
          "people_skill_reminders_action_id_fkey" =>
            foreign_key("action_id", "people_skill_actions")
        },
        checks: %{
          "people_skill_reminders_rule" =>
            check(
              "(rule)::text = ANY ((ARRAY['overdue_reassessment'::character varying, " <>
                "'expiring_certificate'::character varying, " <>
                "'overdue_action'::character varying, " <>
                "'coverage_gap'::character varying])::text[])"
            ),
          "people_skill_reminders_state" =>
            check(
              "(state)::text = ANY ((ARRAY['pending'::character varying, " <>
                "'sent'::character varying, 'failed'::character varying])::text[])"
            ),
          "people_skill_reminders_sent" =>
            check("(state)::text <> 'sent'::text OR sent_at IS NOT NULL")
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

  defp append_only(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false)
    }
  end

  defp versioned(table) do
    common(table)
    |> Map.merge(%{
      "code" => column({:varchar, 80}, false),
      "name" => column({:varchar, 160}, false),
      "version" => column(:integer, false),
      "status" => column({:varchar, 16}, false),
      "published_at" => column({:timestamp, 0}, true),
      "retired_at" => column({:timestamp, 0}, true),
      "actor_user_id" => column(:bigint, true)
    })
  end

  defp versioned_indexes(table) do
    %{
      "#{table}_pkey" => index(["id"], true),
      "#{table}_code_version_unique" => index(["company_id", "code", "version"], true),
      "#{table}_one_draft" =>
        index(["company_id", "code"], true, "(status)::text = 'draft'::text"),
      "#{table}_one_published" =>
        index(["company_id", "code"], true, "(status)::text = 'published'::text"),
      "#{table}_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false, where \\ nil),
    do: %{columns: columns, unique: unique, where: where}

  defp check(expression), do: %{expression: expression, validated: true}

  defp foreign_key(column, table),
    do: %{columns: [column], references: {table, ["id"]}, on_delete: :restrict}
end
