defmodule Bilimbi.People.Attendance.SchemaContract do
  @moduledoc "Fresh Bilimbi attendance structures."
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check text is PostgreSQL's canonical form (`pg_get_constraintdef`), which
  # the verifier compares after removing whitespace and parentheses.
  @active_retired "(status)::text = ANY ((ARRAY['active'::character varying, " <>
                    "'retired'::character varying])::text[])"

  def migration_version, do: 20_260_930_180_101

  @impl true
  def tables do
    [
      %{
        name: "people_attendance_daily_summaries",
        columns:
          common("people_attendance_daily_summaries")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "on_date" => column(:date, false),
            "status" => column({:varchar, 32}, false),
            "first_in_at" => column({:timestamp, 0}, true),
            "last_out_at" => column({:timestamp, 0}, true),
            "worked_minutes" => column(:integer, false, {:integer, 0})
          }),
        indexes: %{
          "people_attendance_daily_summaries_pkey" => index(["id"], true),
          "people_attendance_daily_summaries_company_employee_date_unique" =>
            index(["company_id", "employee_id", "on_date"], true),
          "people_attendance_daily_summaries_scope_date_index" =>
            index(["tenant_id", "company_id", "on_date"])
        },
        foreign_keys: %{}
      },
      %{
        name: "people_attendance_clock_facts",
        columns:
          common("people_attendance_clock_facts")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "day_id" => column(:bigint, false),
            "event_key" => column({:varchar, 160}, false),
            "event_type" => column({:varchar, 16}, false),
            "source" => column({:varchar, 32}, false),
            "occurred_at" => column({:timestamp, 0}, false),
            "timezone" => column({:varchar, 100}, false),
            "actor_user_id" => column(:bigint, true),
            "latitude" => column({:numeric, 9, 6}, true),
            "longitude" => column({:numeric, 9, 6}, true),
            "clocking_location_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_attendance_clock_facts_pkey" => index(["id"], true),
          "people_attendance_events_source_key_unique" =>
            index(["company_id", "source", "event_key"], true),
          "people_attendance_clock_facts_employee_time_index" =>
            index(["tenant_id", "company_id", "employee_id", "occurred_at"])
        },
        foreign_keys: %{
          "people_attendance_clock_facts_day_id_fkey" =>
            foreign_key("day_id", "people_attendance_daily_summaries"),
          "people_attendance_clock_facts_clocking_location_id_fkey" =>
            foreign_key("clocking_location_id", "people_attendance_clocking_locations")
        },
        checks: %{
          "people_attendance_clock_facts_point_check" =>
            check("(latitude IS NULL) = (longitude IS NULL)")
        }
      },
      %{
        name: "people_attendance_shift_definitions",
        columns:
          common("people_attendance_shift_definitions")
          |> Map.merge(%{
            "code" => column({:varchar, 40}, false),
            "name" => column({:varchar, 120}, false),
            "start_minute" => column(:integer, false),
            "end_minute" => column(:integer, false),
            "break_minutes" => column(:integer, false, {:integer, 0}),
            "status" => column({:varchar, 16}, false)
          }),
        indexes: %{
          "people_attendance_shift_definitions_pkey" => index(["id"], true),
          "people_attendance_shift_definitions_company_code_unique" =>
            index(["company_id", "code"], true),
          "people_attendance_shift_definitions_status_index" =>
            index(["tenant_id", "company_id", "status"])
        },
        foreign_keys: %{},
        checks: %{
          "people_attendance_shift_definitions_status_check" => check(@active_retired),
          "people_attendance_shift_definitions_span_check" =>
            check(
              "start_minute >= 0 AND start_minute <= 1439 AND end_minute >= 0 AND " <>
                "end_minute <= 1439 AND start_minute <> end_minute AND break_minutes >= 0"
            )
        }
      },
      %{
        name: "people_attendance_roster_entries",
        columns:
          common("people_attendance_roster_entries")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "on_date" => column(:date, false),
            "kind" => column({:varchar, 16}, false),
            "shift_template_id" => column(:bigint, true),
            "published_kind" => column({:varchar, 16}, true),
            "published_shift_template_id" => column(:bigint, true),
            "published_at" => column({:timestamp, 0}, true),
            "published_by_user_id" => column(:bigint, true),
            "revision" => column(:integer, false, {:integer, 1}),
            "updated_by_user_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_attendance_roster_entries_pkey" => index(["id"], true),
          "people_attendance_roster_entries_company_employee_date_unique" =>
            index(["company_id", "employee_id", "on_date"], true),
          "people_attendance_roster_entries_date_index" =>
            index(["tenant_id", "company_id", "on_date"])
        },
        foreign_keys: %{
          "people_attendance_roster_entries_shift_template_id_fkey" =>
            foreign_key("shift_template_id", "people_attendance_shift_definitions"),
          "people_attendance_roster_entries_published_template_fkey" =>
            foreign_key("published_shift_template_id", "people_attendance_shift_definitions")
        },
        checks: %{
          "people_attendance_roster_entries_kind_check" =>
            check(
              "(kind)::text = ANY ((ARRAY['shift'::character varying, " <>
                "'rest'::character varying, 'none'::character varying])::text[]) AND " <>
                "((kind)::text = 'shift'::text) = (shift_template_id IS NOT NULL)"
            ),
          "people_attendance_roster_entries_published_check" =>
            check(
              "published_kind IS NULL AND published_shift_template_id IS NULL AND " <>
                "published_at IS NULL OR (published_kind)::text = ANY " <>
                "((ARRAY['shift'::character varying, 'rest'::character varying])::text[]) " <>
                "AND published_at IS NOT NULL AND ((published_kind)::text = 'shift'::text) = " <>
                "(published_shift_template_id IS NOT NULL)"
            )
        }
      },
      %{
        name: "people_attendance_clocking_locations",
        columns:
          common("people_attendance_clocking_locations")
          |> Map.merge(%{
            "code" => column({:varchar, 40}, false),
            "name" => column({:varchar, 120}, false),
            "latitude" => column({:numeric, 9, 6}, false),
            "longitude" => column({:numeric, 9, 6}, false),
            "radius_meters" => column(:integer, false),
            "status" => column({:varchar, 16}, false)
          }),
        indexes: %{
          "people_attendance_clocking_locations_pkey" => index(["id"], true),
          "people_attendance_clocking_locations_company_code_unique" =>
            index(["company_id", "code"], true),
          "people_attendance_clocking_locations_status_index" =>
            index(["tenant_id", "company_id", "status"])
        },
        foreign_keys: %{},
        checks: %{
          "people_attendance_clocking_locations_status_check" => check(@active_retired),
          "people_attendance_clocking_locations_point_check" =>
            check(
              "latitude >= ('-90'::integer)::numeric AND latitude <= (90)::numeric AND " <>
                "longitude >= ('-180'::integer)::numeric AND longitude <= (180)::numeric " <>
                "AND radius_meters > 0"
            )
        }
      },
      %{
        name: "people_attendance_corrections",
        columns:
          common("people_attendance_corrections")
          |> Map.merge(%{
            "employee_id" => column(:bigint, false),
            "request_key" => column({:varchar, 160}, false),
            "event_type" => column({:varchar, 16}, false),
            "proposed_at" => column({:timestamp, 0}, false),
            "on_date" => column(:date, false),
            "timezone" => column({:varchar, 100}, false),
            "reason" => column({:varchar, 500}, false),
            "status" => column({:varchar, 16}, false),
            "requested_by_user_id" => column(:bigint, false),
            "decided_by_user_id" => column(:bigint, true),
            "decided_at" => column({:timestamp, 0}, true),
            "decision_note" => column({:varchar, 500}, true),
            "applied_clock_event_id" => column(:bigint, true)
          }),
        indexes: %{
          "people_attendance_corrections_pkey" => index(["id"], true),
          "people_attendance_corrections_company_key_unique" =>
            index(["company_id", "request_key"], true),
          "people_attendance_corrections_status_index" =>
            index(["tenant_id", "company_id", "status"]),
          "people_attendance_corrections_employee_date_index" =>
            index(["company_id", "employee_id", "on_date"])
        },
        foreign_keys: %{
          "people_attendance_corrections_applied_event_fkey" =>
            foreign_key("applied_clock_event_id", "people_attendance_clock_facts")
        },
        checks: %{
          "people_attendance_corrections_state_check" =>
            check(
              "(event_type)::text = ANY ((ARRAY['in'::character varying, " <>
                "'out'::character varying])::text[]) AND (status)::text = ANY " <>
                "((ARRAY['pending'::character varying, 'approved'::character varying, " <>
                "'rejected'::character varying, 'cancelled'::character varying])::text[]) " <>
                "AND ((status)::text = 'pending'::text) = (decided_at IS NULL) AND " <>
                "((status)::text = 'pending'::text) = (decided_by_user_id IS NULL) AND " <>
                "((status)::text = 'approved'::text) = (applied_clock_event_id IS NOT NULL)"
            )
        }
      },
      %{
        name: "people_attendance_allowance_policies",
        columns:
          common("people_attendance_allowance_policies")
          |> Map.merge(%{
            "code" => column({:varchar, 40}, false),
            "name" => column({:varchar, 120}, false),
            "unit" => column({:varchar, 32}, false),
            "value" => column({:numeric, 14, 4}, false),
            "currency" => column({:varchar, 3}, false),
            "effective_from" => column(:date, false),
            "effective_until" => column(:date, true),
            "status" => column({:varchar, 16}, false, {:string, "active"})
          }),
        indexes: %{
          "people_attendance_allowance_policies_pkey" => index(["id"], true),
          "people_attendance_allowance_policies_company_code_from_unique" =>
            index(["company_id", "code", "effective_from"], true),
          "people_attendance_allowance_policies_company_effective_index" =>
            index(["tenant_id", "company_id", "status", "effective_from"])
        },
        foreign_keys: %{},
        checks: %{
          "people_attendance_allowance_policies_status_check" => check(@active_retired),
          "people_attendance_allowance_policies_value_check" => check("value > 0::numeric"),
          "people_attendance_allowance_policies_period_check" =>
            check("effective_until IS NULL OR effective_until >= effective_from")
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

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp foreign_key(column, table),
    do: %{columns: [column], references: {table, ["id"]}, on_delete: :restrict}

  defp check(expression), do: %{expression: expression, validated: true}
end
