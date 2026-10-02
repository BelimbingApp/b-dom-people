defmodule Bilimbi.People.Progression.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities:
          ~w(people.progression.policy.view people.progression.policy.manage people.progression.self.view)
      },
      menu: [
        %{
          id: "people.development.progression",
          label: "Progression",
          parent: "people.development",
          route: "/people/progression",
          capability: "people.progression.policy.view",
          icon: "flag",
          order: 110
        },
        %{
          id: "people.my_work.standing",
          label: "My standing",
          parent: "people.my_work",
          route: "/people/progression/my",
          capability: {:any_of, ~w(people.progression.self.view people.performance.self.view)},
          icon: "user-circle",
          order: 70
        }
      ]
    }
  end
end
