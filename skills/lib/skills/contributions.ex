defmodule Bilimbi.People.Skills.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: [
          "people.skills.catalog.view",
          "people.skills.catalog.manage",
          "people.skills.profiles.publish"
        ]
      },
      menu: [
        %{
          id: "people.development.skills",
          label: "Skills",
          icon: "puzzle-piece",
          parent: "people.development",
          route: "/people/skills",
          capability: "people.skills.catalog.view",
          order: 10
        }
      ]
    }
  end
end
