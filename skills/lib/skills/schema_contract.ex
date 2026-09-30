defmodule Bilimbi.People.Skills.SchemaContract do
  @moduledoc "Fresh Bilimbi skills catalog, scale and requirement profile schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.
  @status_check "(status)::text = ANY ((ARRAY['draft'::character varying, " <>
                  "'published'::character varying, 'retired'::character varying])::text[])"

  def migration_version, do: 20_260_930_181_101

  @impl true
  def tables do
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

  defp common(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
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
