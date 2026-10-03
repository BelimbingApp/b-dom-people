defmodule Bilimbi.People.Performance.SchemaContract do
  @moduledoc "Fresh Bilimbi Performance schema, checked after migration."
  @behaviour Bilimbi.Base.Database.SchemaContract
  def migration_version, do: 20_261_001_070_701
  @impl true
  def tables do
    [
      %{
        name: "people_performance_descriptions",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_descriptions_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "code" => column(:text, false),
          "version" => column(:integer, false),
          "position_id" => column(:bigint, false),
          "position_version" => column(:integer, false),
          "effective_from" => column(:date, false),
          "effective_to" => column(:date, true),
          "purpose" => column(:text, false),
          "responsibilities" => column(:text, false),
          "duties" => column(:text, false),
          "authority" => column(:text, false),
          "qualifications" => column(:text, false),
          "competency_links" => column(:jsonb, false),
          "status" => column(:text, false),
          "published_at" => column({:timestamp, 0}, true),
          "published_by_user_id" => column(:bigint, true),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_descriptions_pkey" => index(["id"], true),
          "people_performance_descriptions_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_descriptions_scope_idx" =>
            index(["tenant_id", "company_id"], false),
          "people_performance_descriptions_identity_unique" =>
            index(["company_id", "code", "version"], true)
        },
        foreign_keys: %{},
        checks: %{
          "people_performance_descriptions_content" => %{
            expression:
              "(((length(btrim(code)) > 0) AND (length(btrim(purpose)) > 0) AND (length(btrim(responsibilities)) > 0) AND (length(btrim(duties)) > 0) AND (length(btrim(authority)) > 0) AND (length(btrim(qualifications)) > 0) AND (jsonb_typeof((competency_links -> 'profiles'::text)) = 'array'::text) AND (jsonb_array_length((competency_links -> 'profiles'::text)) > 0))"
          },
          "people_performance_descriptions_dates" => %{
            expression: "(((effective_to IS NULL) OR (effective_to >= effective_from))"
          },
          "people_performance_descriptions_version" => %{
            expression: "(((version > 0) AND (position_version > 0))"
          },
          "people_performance_descriptions_workflow" => %{
            expression:
              "((((status = 'draft'::text) AND (published_at IS NULL) AND (published_by_user_id IS NULL)) OR ((status = 'published'::text) AND (published_at IS NOT NULL) AND (published_by_user_id IS NOT NULL)))"
          }
        }
      },
      %{
        name: "people_performance_kpi_definitions",
        columns: %{
          "id" =>
            column(:bigint, false, {:sequence, "people_performance_kpi_definitions_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "code" => column(:text, false),
          "version" => column(:integer, false),
          "name" => column(:text, false),
          "purpose" => column(:text, false),
          "unit" => column(:text, false),
          "measure" => column(:text, false),
          "source_reference" => column(:text, false),
          "calculation_version" => column(:text, false),
          "direction" => column(:text, false),
          "rubric" => column(:text, true),
          "precision" => column(:integer, false),
          "interpretation" => column(:text, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_kpi_definitions_pkey" => index(["id"], true),
          "people_performance_kpi_definitions_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_kpi_definitions_scope_idx" =>
            index(["tenant_id", "company_id"], false),
          "people_performance_kpi_definitions_identity_unique" =>
            index(["company_id", "code", "version"], true)
        },
        foreign_keys: %{},
        checks: %{
          "people_performance_kpi_definitions_content" => %{
            expression:
              "(((length(btrim(code)) > 0) AND (length(btrim(name)) > 0) AND (length(btrim(purpose)) > 0) AND (length(btrim(unit)) > 0) AND (length(btrim(measure)) > 0) AND (length(btrim(source_reference)) > 0) AND (length(btrim(calculation_version)) > 0) AND (length(btrim(interpretation)) > 0))"
          },
          "people_performance_kpi_definitions_direction" => %{
            expression:
              "(((direction = ANY (ARRAY['higher'::text, 'lower'::text, 'band'::text, 'rubric'::text])) AND ((direction <> 'rubric'::text) OR (COALESCE(length(btrim(rubric)), 0) > 0)))"
          },
          "people_performance_kpi_definitions_version" => %{
            expression: "(((version > 0) AND ((\"precision\" >= 0) AND (\"precision\" <= 8)))"
          }
        }
      },
      %{
        name: "people_performance_kpi_targets",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_kpi_targets_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "definition_id" => column(:bigint, false),
          "definition_version" => column(:integer, false),
          "employee_id" => column(:bigint, false),
          "target" => column(:text, false),
          "period_start" => column(:date, false),
          "period_end" => column(:date, false),
          "effective_from" => column(:date, false),
          "version" => column(:integer, false),
          "supersedes_id" => column(:bigint, true),
          "change_reason" => column(:text, true),
          "confidential" => column(:boolean, false),
          "status" => column(:text, false),
          "review_note" => column(:text, true),
          "reviewed_by_user_id" => column(:bigint, true),
          "published_by_user_id" => column(:bigint, true),
          "published_at" => column({:timestamp, 0}, true),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_kpi_targets_pkey" => index(["id"], true),
          "people_performance_kpi_targets_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_kpi_targets_scope_idx" => index(["tenant_id", "company_id"], false),
          "people_performance_kpi_targets_supersedes_unique" => index(["supersedes_id"], true)
        },
        foreign_keys: %{
          "people_performance_kpi_targets_definition_id_scope_fk" => %{
            columns: ["definition_id", "tenant_id", "company_id"],
            references: {"people_performance_kpi_definitions", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          },
          "people_performance_kpi_targets_supersedes_id_scope_fk" => %{
            columns: ["supersedes_id", "tenant_id", "company_id"],
            references: {"people_performance_kpi_targets", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_performance_kpi_targets_content" => %{
            expression: "((length(btrim(target)) > 0)"
          },
          "people_performance_kpi_targets_correction" => %{
            expression:
              "((((supersedes_id IS NULL) AND (version = 1) AND (change_reason IS NULL)) OR ((supersedes_id IS NOT NULL) AND (version > 1) AND (COALESCE(length(btrim(change_reason)), 0) > 0)))"
          },
          "people_performance_kpi_targets_dates" => %{
            expression:
              "(((period_end >= period_start) AND ((effective_from >= period_start) AND (effective_from <= period_end)))"
          },
          "people_performance_kpi_targets_version" => %{
            expression: "(((version > 0) AND (definition_version > 0))"
          },
          "people_performance_kpi_targets_workflow" => %{
            expression:
              "((((status = 'proposed'::text) AND (review_note IS NULL) AND (reviewed_by_user_id IS NULL) AND (published_at IS NULL) AND (published_by_user_id IS NULL)) OR ((status = 'reviewed'::text) AND (COALESCE(length(btrim(review_note)), 0) > 0) AND (reviewed_by_user_id IS NOT NULL) AND (reviewed_by_user_id <> actor_user_id) AND (published_at IS NULL) AND (published_by_user_id IS NULL)) OR ((status = 'published'::text) AND (NOT confidential) AND (COALESCE(length(btrim(review_note)), 0) > 0) AND (reviewed_by_user_id IS NOT NULL) AND (reviewed_by_user_id <> actor_user_id) AND (published_at IS NOT NULL) AND (published_by_user_id IS NOT NULL) AND (published_by_user_id <> actor_user_id)))"
          }
        }
      },
      %{
        name: "people_performance_evidence",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_evidence_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "employee_id" => column(:bigint, false),
          "window_start" => column(:date, false),
          "window_end" => column(:date, false),
          "evidence" => column(:text, false),
          "source_reference" => column(:text, false),
          "source_version" => column(:text, false),
          "supersedes_id" => column(:bigint, true),
          "change_reason" => column(:text, true),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_evidence_pkey" => index(["id"], true),
          "people_performance_evidence_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_evidence_scope_idx" => index(["tenant_id", "company_id"], false),
          "people_performance_evidence_supersedes_unique" => index(["supersedes_id"], true)
        },
        foreign_keys: %{
          "people_performance_evidence_supersedes_id_scope_fk" => %{
            columns: ["supersedes_id", "tenant_id", "company_id"],
            references: {"people_performance_evidence", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_performance_evidence_content" => %{
            expression:
              "(((length(btrim(evidence)) > 0) AND (length(btrim(source_reference)) > 0) AND (length(btrim(source_version)) > 0))"
          },
          "people_performance_evidence_correction" => %{
            expression:
              "((((supersedes_id IS NULL) AND (change_reason IS NULL)) OR ((supersedes_id IS NOT NULL) AND (COALESCE(length(btrim(change_reason)), 0) > 0)))"
          },
          "people_performance_evidence_dates" => %{
            expression: "((window_end >= window_start)"
          }
        }
      },
      %{
        name: "people_performance_appraisals",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_appraisals_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "employee_id" => column(:bigint, false),
          "description_id" => column(:bigint, false),
          "period_start" => column(:date, false),
          "period_end" => column(:date, false),
          "cutoff_at" => column({:timestamp, 0}, false),
          "outcome" => column(:text, false),
          "rationale" => column(:text, false),
          "version" => column(:integer, false),
          "supersedes_id" => column(:bigint, true),
          "change_reason" => column(:text, true),
          "status" => column(:text, false),
          "released_at" => column({:timestamp, 0}, true),
          "released_by_user_id" => column(:bigint, true),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_appraisals_pkey" => index(["id"], true),
          "people_performance_appraisals_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_appraisals_scope_idx" => index(["tenant_id", "company_id"], false),
          "people_performance_appraisals_supersedes_unique" => index(["supersedes_id"], true)
        },
        foreign_keys: %{
          "people_performance_appraisals_supersedes_id_scope_fk" => %{
            columns: ["supersedes_id", "tenant_id", "company_id"],
            references: {"people_performance_appraisals", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          },
          "people_performance_appraisals_description_id_scope_fk" => %{
            columns: ["description_id", "tenant_id", "company_id"],
            references: {"people_performance_descriptions", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_performance_appraisals_content" => %{
            expression: "(((length(btrim(outcome)) > 0) AND (length(btrim(rationale)) > 0))"
          },
          "people_performance_appraisals_correction" => %{
            expression:
              "((((supersedes_id IS NULL) AND (version = 1) AND (change_reason IS NULL)) OR ((supersedes_id IS NOT NULL) AND (version > 1) AND (COALESCE(length(btrim(change_reason)), 0) > 0)))"
          },
          "people_performance_appraisals_dates" => %{
            expression: "(((period_end >= period_start) AND ((cutoff_at)::date >= period_end))"
          },
          "people_performance_appraisals_workflow" => %{
            expression:
              "((((status = 'draft'::text) AND (released_at IS NULL) AND (released_by_user_id IS NULL)) OR ((status = 'released'::text) AND (released_at IS NOT NULL) AND (released_by_user_id IS NOT NULL) AND (released_by_user_id <> actor_user_id)))"
          }
        }
      },
      %{
        name: "people_performance_review_evidence",
        columns: %{
          "id" =>
            column(:bigint, false, {:sequence, "people_performance_review_evidence_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "review_id" => column(:bigint, false),
          "observation_id" => column(:bigint, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_review_evidence_pkey" => index(["id"], true),
          "people_performance_review_evidence_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_review_evidence_scope_idx" =>
            index(["tenant_id", "company_id"], false),
          "people_performance_review_evidence_identity_unique" =>
            index(["review_id", "observation_id"], true)
        },
        foreign_keys: %{
          "people_performance_review_evidence_review_id_scope_fk" => %{
            columns: ["review_id", "tenant_id", "company_id"],
            references: {"people_performance_appraisals", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          },
          "people_performance_review_evidence_observation_id_scope_fk" => %{
            columns: ["observation_id", "tenant_id", "company_id"],
            references: {"people_performance_evidence", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{}
      },
      %{
        name: "people_performance_review_targets",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_review_targets_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "review_id" => column(:bigint, false),
          "target_id" => column(:bigint, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_review_targets_pkey" => index(["id"], true),
          "people_performance_review_targets_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_review_targets_scope_idx" =>
            index(["tenant_id", "company_id"], false),
          "people_performance_review_targets_identity_unique" =>
            index(["review_id", "target_id"], true)
        },
        foreign_keys: %{
          "people_performance_review_targets_review_id_scope_fk" => %{
            columns: ["review_id", "tenant_id", "company_id"],
            references: {"people_performance_appraisals", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          },
          "people_performance_review_targets_target_id_scope_fk" => %{
            columns: ["target_id", "tenant_id", "company_id"],
            references: {"people_performance_kpi_targets", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{}
      },
      %{
        name: "people_performance_responses",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_performance_responses_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "actor_user_id" => column(:bigint, false),
          "review_id" => column(:bigint, false),
          "employee_id" => column(:bigint, false),
          "response" => column(:text, false),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "people_performance_responses_pkey" => index(["id"], true),
          "people_performance_responses_scope_unique" =>
            index(["id", "tenant_id", "company_id"], true),
          "people_performance_responses_scope_idx" => index(["tenant_id", "company_id"], false),
          "people_performance_responses_identity_unique" =>
            index(["review_id", "actor_user_id"], true)
        },
        foreign_keys: %{
          "people_performance_responses_review_id_scope_fk" => %{
            columns: ["review_id", "tenant_id", "company_id"],
            references: {"people_performance_appraisals", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_performance_responses_content" => %{
            expression: "((length(btrim(response)) > 0)"
          }
        }
      }
    ]
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}
end
