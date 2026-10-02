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
        }
      ]
    }
  end
end
