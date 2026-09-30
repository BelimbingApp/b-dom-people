defmodule Bilimbi.People.Organisation.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.organisation.view", "people.organisation.manage"]
      },
      menu: [
        %{
          id: "people.team.organisation",
          label: "Organisation",
          parent: "people.team",
          route: "/people/organisation",
          capability: "people.organisation.view",
          order: 20
        }
      ]
    }
  end
end
