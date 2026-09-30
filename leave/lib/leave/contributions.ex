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
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.leave.self.view", "people.leave.policies.manage"]
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
