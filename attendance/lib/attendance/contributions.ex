defmodule Bilimbi.People.Attendance.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.attendance.timezone" => %{
            type: :string,
            scopes: [:company],
            default: "Etc/UTC",
            label: "Attendance time zone",
            help: "Local date used to group clock events for this company.",
            capability: "people.attendance.rules.manage"
          },
          "people.attendance.self_clock_enabled" => %{
            type: :boolean,
            scopes: [:company],
            default: false,
            label: "Employee clocking",
            help: "Allow linked employee accounts to record their own clock events.",
            capability: "people.attendance.rules.manage"
          },
          "people.attendance.max_shift_hours" => %{
            type: :integer,
            scopes: [:company],
            default: 16,
            minimum: 1,
            maximum: 24,
            label: "Maximum shift length",
            help:
              "Hours after clock-in that a shift stays open; a clock-out within it closes the shift on the clock-in day.",
            capability: "people.attendance.rules.manage"
          },
          "people.attendance.location_required" => %{
            type: :boolean,
            scopes: [:company],
            default: false,
            label: "Require a clocking location",
            help:
              "Refuse clock events that do not carry coordinates inside an active clocking location. Approved adjustments are exempt.",
            capability: "people.attendance.rules.manage"
          },
          "people.attendance.adjustment_window_days" => %{
            type: :integer,
            scopes: [:company],
            default: 7,
            minimum: 1,
            maximum: 366,
            label: "Adjustment request window",
            help:
              "Days, counting today, for which an employee may request a missing clock event.",
            capability: "people.attendance.rules.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: [
          "people.attendance.self.view",
          "people.attendance.rules.manage",
          "people.attendance.roster.manage",
          "people.attendance.adjustments.approve"
        ]
      },
      menu: [
        %{
          id: "people.attendance.my",
          label: "My attendance",
          icon: "clipboard-document-list",
          parent: "people.my_work",
          route: "/people/attendance/my",
          capability: "people.attendance.self.view",
          order: 10
        },
        %{
          id: "people.attendance.rosters",
          label: "Rosters",
          icon: "clipboard-document-list",
          parent: "people.team",
          route: "/people/attendance/rosters",
          capability: "people.attendance.roster.manage",
          order: 30
        },
        %{
          id: "people.attendance.approvals",
          label: "Attendance approvals",
          icon: "shield-check",
          parent: "people.team",
          route: "/people/attendance/approvals",
          capability: "people.attendance.adjustments.approve",
          order: 40
        },
        %{
          id: "people.attendance.rules",
          label: "Attendance rules",
          icon: "clipboard-document-list",
          parent: "people.settings",
          route: "/people/attendance/rules",
          capability: "people.attendance.rules.manage",
          order: 10
        }
      ]
    }
  end
end
