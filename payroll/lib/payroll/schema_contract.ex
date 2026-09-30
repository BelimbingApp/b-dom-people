defmodule Bilimbi.People.Payroll.SchemaContract do
  @moduledoc "Fresh Bilimbi payroll foundation schema; verified after migration."
  @behaviour Bilimbi.Base.Database.SchemaContract
  @impl true
  def tables do
    [
      %{
        name: "people_payroll_classifications",
        columns:
          common("people_payroll_classifications")
          |> Map.merge(%{
            "code" => column({:varchar, 60}, false),
            "name" => column({:varchar, 120}, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true)
          }),
        indexes: %{
          "people_payroll_classifications_pkey" => index(["id"], true),
          "people_payroll_classifications_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"], false)
        },
        foreign_keys: %{},
        checks: %{
          "people_payroll_classifications_dates" => %{
            expression: "effective_to IS NULL OR effective_to >= effective_from",
            validated: true
          }
        }
      },
      %{
        name: "people_payroll_items",
        columns:
          common("people_payroll_items")
          |> Map.merge(%{
            "code" => column({:varchar, 60}, false),
            "name" => column({:varchar, 120}, false),
            "classification_id" => column(:bigint, false),
            "currency" => column({:varchar, 3}, false),
            "amount" => column({:numeric, 20, 6}, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true)
          }),
        indexes: %{
          "people_payroll_items_pkey" => index(["id"], true),
          "people_payroll_items_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"], false)
        },
        foreign_keys: %{
          "people_payroll_items_classification_id_fkey" => %{
            columns: ["classification_id"],
            references: {"people_payroll_classifications", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_payroll_items_dates" => %{
            expression: "effective_to IS NULL OR effective_to >= effective_from",
            validated: true
          },
          "people_payroll_items_money" => %{
            expression: "amount >= (0)::numeric AND (currency)::text ~ '^[A-Z]{3}$'::text",
            validated: true
          }
        }
      },
      %{
        name: "people_payroll_periods",
        columns:
          common("people_payroll_periods")
          |> Map.merge(%{
            "code" => column({:varchar, 60}, false),
            "starts_on" => column(:date, false),
            "ends_on" => column(:date, false),
            "pay_on" => column(:date, false)
          }),
        indexes: %{
          "people_payroll_periods_pkey" => index(["id"], true),
          "people_payroll_periods_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"], false),
          "people_payroll_periods_company_id_code_index" => index(["company_id", "code"], true)
        },
        foreign_keys: %{},
        checks: %{
          "people_payroll_periods_dates" => %{
            expression: "ends_on >= starts_on AND pay_on >= ends_on",
            validated: true
          }
        }
      },
      %{
        name: "people_payroll_mappings",
        columns:
          common("people_payroll_mappings")
          |> Map.merge(%{
            "source_kind" => column({:varchar, 20}, false),
            "source_key" => column({:varchar, 100}, false),
            "item_id" => column(:bigint, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true)
          }),
        indexes: %{
          "people_payroll_mappings_pkey" => index(["id"], true),
          "people_payroll_mappings_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"], false)
        },
        foreign_keys: %{
          "people_payroll_mappings_item_id_fkey" => %{
            columns: ["item_id"],
            references: {"people_payroll_items", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_payroll_mappings_dates" => %{
            expression: "effective_to IS NULL OR effective_to >= effective_from",
            validated: true
          },
          "people_payroll_mappings_source" => %{
            expression:
              "(source_kind)::text = ANY ((ARRAY['leave'::character varying, 'claims'::character varying])::text[])",
            validated: true
          }
        }
      },
      %{
        name: "people_payroll_runs",
        columns:
          common("people_payroll_runs")
          |> Map.merge(%{
            "period_id" => column(:bigint, false),
            "country" => column({:varchar, 100}, false),
            "currency" => column({:varchar, 3}, false),
            "snapshot" => column(:jsonb, false),
            "locked_at" => column({:timestamp, 0}, true),
            "locked_by_actor_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_payroll_runs_pkey" => index(["id"], true),
          "people_payroll_runs_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"], false),
          "people_payroll_runs_period_id_currency_index" => index(["period_id", "currency"], true)
        },
        foreign_keys: %{
          "people_payroll_runs_period_id_fkey" => %{
            columns: ["period_id"],
            references: {"people_payroll_periods", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_payroll_runs_lock" => %{
            expression: "(locked_at IS NULL) = (locked_by_actor_id IS NULL)",
            validated: true
          },
          "people_payroll_runs_currency" => %{
            expression: "(currency)::text ~ '^[A-Z]{3}$'::text",
            validated: true
          }
        }
      },
      %{
        name: "people_payroll_attendance_rule_pay_items",
        columns:
          common("people_payroll_attendance_rule_pay_items")
          |> Map.merge(%{
            "attendance_rule_code" => column({:varchar, 40}, false),
            "item_id" => column(:bigint, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true)
          }),
        indexes: %{
          "people_payroll_attendance_rule_pay_items_pkey" => index(["id"], true),
          "people_payroll_attendance_rule_pay_items_company_index" =>
            index(["tenant_id", "company_id"], false)
        },
        foreign_keys: %{
          "people_payroll_attendance_rule_pay_items_item_id_fkey" => %{
            columns: ["item_id"],
            references: {"people_payroll_items", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_payroll_attendance_rule_pay_items_dates" => %{
            expression: "effective_to IS NULL OR effective_to >= effective_from",
            validated: true
          }
        }
      }
    ] ++ output_tables()
  end

  defp output_tables do
    [
      output_table("contributions", %{
        "employee_id" => column(:bigint, false), "item_id" => column(:bigint, false),
        "source_key" => column({:varchar, 120}, false), "evidence" => column({:varchar, 500}, false),
        "on_date" => column(:date, false), "units" => column({:numeric, 20, 6}, false),
        "direction" => column({:varchar, 20}, false)
      }, %{ "people_payroll_contributions_company_id_source_key_index" => index(["company_id", "source_key"], true)}, %{
        "people_payroll_contributions_units" => %{expression: "units > (0)::numeric", validated: true},
        "people_payroll_contributions_direction" => %{expression: "(direction)::text = ANY ((ARRAY['earning'::character varying, 'deduction'::character varying, 'employer'::character varying])::text[])", validated: true}
      }, %{"people_payroll_contributions_item_id_fkey" => %{columns: ["item_id"], references: {"people_payroll_items", ["id"]}, on_delete: :restrict}}),
      output_table("result_lines", %{"contribution_id" => column(:bigint, false), "employee_id" => column(:bigint, false), "direction" => column({:varchar, 20}, false), "amount" => column({:numeric, 40, 12}, false)},
        %{"people_payroll_result_lines_contribution_id_index" => index(["contribution_id"], true)},
        %{"people_payroll_result_lines_amount" => %{expression: "amount >= (0)::numeric", validated: true}},
        %{"people_payroll_result_lines_contribution_id_fkey" => %{columns: ["contribution_id"], references: {"people_payroll_contributions", ["id"]}, on_delete: :restrict}}),
      output_table("calculations", %{"snapshot" => column(:jsonb, false), "digest" => column({:varchar, 64}, false)},
        %{"people_payroll_calculations_run_id_index" => index(["run_id"], true)}, %{}, %{}),
      output_table("decisions", %{"outcome" => column({:varchar, 20}, false), "reason" => column({:varchar, 500}, false)},
        %{"people_payroll_decisions_run_id_index" => index(["run_id"], true)},
        %{"people_payroll_decisions_outcome" => %{expression: "(outcome)::text = ANY ((ARRAY['approved'::character varying, 'rejected'::character varying])::text[])", validated: true}}, %{}),
      output_table("documents", %{"employee_id" => column(:bigint, true), "artifact_id" => column(:uuid, false), "kind" => column({:varchar, 20}, false)},
        %{"people_payroll_documents_artifact_id_index" => index(["artifact_id"], true)},
        %{"people_payroll_documents_kind" => %{expression: "(kind)::text = 'report'::text AND employee_id IS NULL OR (kind)::text = 'payslip'::text AND employee_id IS NOT NULL", validated: true}}, %{})
    ]
  end

  defp output_table(suffix, columns, indexes, checks, fks) do
    name = "people_payroll_" <> suffix
    %{name: name,
      columns: Map.merge(common(name), Map.put(columns, "run_id", column(:bigint, false))),
      indexes: Map.merge(%{ "#{name}_pkey" => index(["id"], true),
        "#{name}_tenant_id_company_id_index" => index(["tenant_id", "company_id"], false)}, indexes),
      checks: checks,
      foreign_keys: Map.put(fks, "#{name}_run_id_fkey", %{columns: ["run_id"], references: {"people_payroll_runs", ["id"]}, on_delete: :restrict})}
  end

  defp common(table),
    do: %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "created_by_actor_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}
end
