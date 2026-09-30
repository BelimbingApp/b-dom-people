defmodule Bilimbi.People.Leave.SchemaContract do
  @moduledoc "Fresh Bilimbi leave structures."
  @behaviour Bilimbi.Base.Database.SchemaContract

  def migration_version, do: 20_260_930_200_101

  @impl true
  def tables do
    [
      %{
        name: "people_leave_types",
        columns:
          common("people_leave_types")
          |> Map.merge(%{
            "code" => column({:varchar, 40}, false),
            "name" => column({:varchar, 120}, false),
            "unit" => column({:varchar, 8}, false),
            "paid" => column(:boolean, false),
            "balance_required" => column(:boolean, false, {:boolean, true}),
            "status" => column({:varchar, 16}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "people_leave_types_pkey" => index(["id"], true),
          "people_leave_types_company_code_unique" => index(["company_id", "code"], true),
          "people_leave_types_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_leave_policies",
        columns:
          common("people_leave_policies")
          |> Map.merge(%{
            "leave_type_id" => column(:bigint, false),
            "version" => column(:integer, false),
            "effective_from" => column(:date, false),
            "effective_to" => column(:date, true),
            "entitlement" => column({:numeric, 8, 2}, false),
            "carry_forward_cap" => column({:numeric, 8, 2}, true),
            "actor_user_id" => column(:bigint, true),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "people_leave_policies_pkey" => index(["id"], true),
          "people_leave_policies_type_version_unique" =>
            index(["leave_type_id", "version"], true),
          "people_leave_policies_type_from_unique" =>
            index(["leave_type_id", "effective_from"], true),
          "people_leave_policies_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        checks: %{
          "people_leave_policies_effective_range" =>
            check("effective_to IS NULL OR effective_to >= effective_from"),
          "people_leave_policies_entitlement_non_negative" => check("entitlement >= 0::numeric"),
          "people_leave_policies_carry_forward_cap_non_negative" =>
            check("carry_forward_cap IS NULL OR carry_forward_cap >= 0::numeric")
        },
        foreign_keys: %{
          "people_leave_policies_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          }
        }
      },
      %{
        name: "people_leave_ledger_entries",
        columns:
          common("people_leave_ledger_entries")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "leave_type_id" => column(:bigint, false),
            "leave_year" => column(:integer, false),
            "entry_type" => column({:varchar, 24}, false),
            "quantity" => column({:numeric, 10, 2}, false),
            "unit" => column({:varchar, 8}, false),
            "policy_id" => column(:bigint, true),
            "policy_version" => column(:integer, true),
            "occurred_on" => column(:date, false),
            "source" => column({:varchar, 32}, false),
            "entry_key" => column({:varchar, 160}, false),
            "actor_user_id" => column(:bigint, true),
            "note" => column({:varchar, 500}, true)
          }),
        indexes: %{
          "people_leave_ledger_entries_pkey" => index(["id"], true),
          "people_leave_ledger_entries_source_key_unique" =>
            index(["company_id", "source", "entry_key"], true),
          # PostgreSQL truncates the generated name to 63 bytes.
          "people_leave_ledger_entries_tenant_id_company_id_employee_id_le" =>
            index(["tenant_id", "company_id", "employee_id", "leave_year"])
        },
        foreign_keys: %{
          "people_leave_ledger_entries_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          },
          "people_leave_ledger_entries_policy_id_fkey" => %{
            columns: ["policy_id"],
            references: {"people_leave_policies", ["id"]},
            on_delete: :restrict
          }
        }
      },
      %{
        name: "people_leave_requests",
        columns:
          common("people_leave_requests")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "leave_type_id" => column(:bigint, false),
            "leave_year" => column(:integer, false),
            "starts_on" => column(:date, false),
            "ends_on" => column(:date, false),
            "day_part" => column({:varchar, 8}, false),
            "quantity" => column({:numeric, 10, 2}, false),
            "unit" => column({:varchar, 8}, false),
            "status" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "request_key" => column({:varchar, 160}, false),
            "requested_by_user_id" => column(:bigint, false),
            "decided_by_user_id" => column(:bigint, true),
            "decided_at" => column({:timestamp, 6}, true),
            "decision_note" => column({:varchar, 500}, true),
            "cancelled_by_user_id" => column(:bigint, true),
            "cancelled_at" => column({:timestamp, 6}, true),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "people_leave_requests_pkey" => index(["id"], true),
          "people_leave_requests_employee_key_unique" =>
            index(["company_id", "employee_id", "request_key"], true),
          "people_leave_requests_tenant_id_company_id_status_index" =>
            index(["tenant_id", "company_id", "status"]),
          "people_leave_requests_employee_year_index" =>
            index(["tenant_id", "company_id", "employee_id", "leave_year"])
        },
        foreign_keys: %{
          "people_leave_requests_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_leave_requests_date_range" => check("ends_on >= starts_on"),
          "people_leave_requests_quantity_positive" => check("quantity > 0::numeric"),
          "people_leave_requests_status" =>
            check(
              "(status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying, 'cancelled'::character varying])::text[])"
            ),
          "people_leave_requests_day_part" =>
            check(
              "(day_part)::text = ANY ((ARRAY['full'::character varying, 'am'::character varying, 'pm'::character varying, 'hours'::character varying])::text[])"
            )
        }
      },
      %{
        name: "people_leave_request_days",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_leave_request_days_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "employee_id" => column(:bigint, false),
          "request_id" => column(:bigint, false),
          "on_date" => column(:date, false),
          "am" => column(:boolean, false),
          "pm" => column(:boolean, false),
          "quantity" => column({:numeric, 10, 2}, false),
          "active" => column(:boolean, false)
        },
        indexes: %{
          "people_leave_request_days_pkey" => index(["id"], true),
          "people_leave_request_days_request_date_unique" =>
            index(["request_id", "on_date"], true),
          "people_leave_request_days_am_unique" =>
            partial_index(["company_id", "employee_id", "on_date"], "(active AND am)"),
          "people_leave_request_days_pm_unique" =>
            partial_index(["company_id", "employee_id", "on_date"], "(active AND pm)")
        },
        foreign_keys: %{
          "people_leave_request_days_request_id_fkey" => %{
            columns: ["request_id"],
            references: {"people_leave_requests", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{"people_leave_request_days_slot" => check("am OR pm")}
      },
      %{
        name: "people_leave_request_events",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "people_leave_request_events_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "request_id" => column(:bigint, false),
          "from_status" => column({:varchar, 16}, true),
          "to_status" => column({:varchar, 16}, false),
          "actor_user_id" => column(:bigint, false),
          "note" => column({:varchar, 500}, true),
          "occurred_at" => column({:timestamp, 6}, false)
        },
        indexes: %{
          "people_leave_request_events_pkey" => index(["id"], true),
          "people_leave_request_events_request_id_index" => index(["request_id"])
        },
        foreign_keys: %{
          "people_leave_request_events_request_id_fkey" => %{
            columns: ["request_id"],
            references: {"people_leave_requests", ["id"]},
            on_delete: :restrict
          }
        }
      },
      %{
        name: "people_leave_carry_forward_skips",
        columns:
          common("people_leave_carry_forward_skips")
          |> Map.merge(%{
            "from_year" => column(:integer, false),
            "employee_id" => column(:bigint, false),
            "employee_label" => column({:varchar, 300}, false),
            "leave_type_id" => column(:bigint, false),
            "reason" => column({:varchar, 24}, false),
            "blocking_year" => column(:integer, false)
          }),
        indexes: %{
          "people_leave_carry_forward_skips_pkey" => index(["id"], true),
          "people_leave_carry_forward_skips_unique" =>
            index(["company_id", "from_year", "employee_id", "leave_type_id"], true)
        },
        foreign_keys: %{
          "people_leave_carry_forward_skips_leave_type_id_fkey" => %{
            columns: ["leave_type_id"],
            references: {"people_leave_types", ["id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "people_leave_carry_forward_skips_reason" =>
            check(
              "(reason)::text = ANY ((ARRAY['pending'::character varying, 'previous_year_open'::character varying])::text[])"
            )
        }
      }
    ]
  end

  # The ledger has no updated_at: entries are append-only.
  defp common(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false),
      "inserted_at" => column({:timestamp, 0}, false)
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp partial_index(columns, where), do: %{columns: columns, unique: true, where: where}

  defp check(expression), do: %{expression: expression, validated: true}
end
