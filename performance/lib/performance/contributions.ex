defmodule Bilimbi.People.Performance.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ~w(people.performance.view people.performance.descriptions.manage
          people.performance.kpis.submit people.performance.kpis.review
          people.performance.kpis.approve people.performance.reviews.submit
          people.performance.reviews.approve people.performance.self.view)
      },
      menu: [
        %{
          id: "people.development.performance",
          label: "Performance reviews",
          parent: "people.development",
          route: "/people/performance",
          capability: "people.performance.view",
          icon: "clipboard-document-list",
          order: 100
        },
        %{
          id: "people.my_work.performance",
          label: "My performance",
          parent: "people.my_work",
          route: "/people/performance/my",
          capability: "people.performance.self.view",
          icon: "user-circle",
          order: 60
        }
      ]
    }
  end
end
