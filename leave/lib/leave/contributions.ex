defmodule Bilimbi.People.Leave.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.leave.year_start_month" => %{
            type: :integer,
            scopes: [:company],
            default: 1,
            minimum: 1,
            maximum: 12,
            label: "Leave year start month",
            help:
              "Month in which this company's leave year begins; entitlements are granted per leave year.",
            capability: "people.leave.policies.manage"
          },
          "people.leave.working_weekdays" => %{
            type: :array,
            scopes: [:company],
            default: [1, 2, 3, 4, 5],
            label: "Leave working weekdays",
            help:
              "ISO weekday numbers (1 is Monday) counted as leave days; other weekdays and calendar exceptions are not.",
            capability: "people.leave.policies.manage"
          },
          "people.leave.request_backdate_days" => %{
            type: :integer,
            scopes: [:company],
            default: 30,
            minimum: 0,
            maximum: 366,
            label: "Leave request backdating",
            help: "How many days before today a leave request may start.",
            capability: "people.leave.policies.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: [
          "people.leave.self.view",
          "people.leave.requests.approve",
          "people.leave.policies.manage"
        ]
      },
      menu: [
        %{
          id: "people.leave.my",
          label: "My leave",
          icon: "clipboard-document-list",
          parent: "people.my_work",
          route: "/people/leave/my",
          capability: "people.leave.self.view",
          order: 20
        },
        %{
          id: "people.leave.approvals",
          label: "Leave approvals",
          icon: "shield-check",
          parent: "people.team",
          route: "/people/leave/requests",
          capability: "people.leave.requests.approve",
          order: 50
        },
        %{
          id: "people.leave.policies",
          label: "Leave policies",
          icon: "clipboard-document-list",
          parent: "people.settings",
          route: "/people/leave/policies",
          capability: "people.leave.policies.manage",
          order: 20
        }
      ]
    }
  end
end
