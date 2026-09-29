defmodule Bilimbi.People.EmployeeWorkspace.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: [
          "people.employees.view",
          "people.employees.manage",
          "people.employees.review"
        ],
        roles: %{
          "tenant_owner" => %{
            capabilities: [
              "people.employees.view",
              "people.employees.manage",
              "people.employees.review"
            ]
          }
        }
      },
      menu: [
        %{
          id: "people.team",
          label: "Team",
          parent: "people",
          route: nil,
          capability: nil,
          order: 20
        },
        %{
          id: "people.team.employees",
          label: "Employees",
          parent: "people.team",
          route: "/people/employees",
          capability: "people.employees.view",
          order: 10
        }
      ]
    }
  end
end
