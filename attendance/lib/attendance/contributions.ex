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
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.attendance.self.view", "people.attendance.rules.manage"]
      },
      menu: [
        %{
          id: "people.my_work",
          label: "My work",
          icon: "user-circle",
          parent: "people",
          route: nil,
          capability: nil,
          order: 10
        },
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
          id: "people.settings",
          label: "Settings",
          icon: "cog-6-tooth",
          parent: "people",
          route: nil,
          capability: nil,
          order: 90
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
