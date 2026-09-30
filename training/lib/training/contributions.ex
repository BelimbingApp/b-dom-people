defmodule Bilimbi.People.Training.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities:
          ~w(people.training.courses.view people.training.courses.manage people.training.sessions.view people.training.sessions.manage)
      },
      menu: [
        %{
          id: "people.development.courses",
          parent: "people.development",
          label: "Courses",
          icon: "clipboard-document-list",
          route: "/people/training/courses",
          capability: "people.training.courses.view",
          order: 40
        },
        %{
          id: "people.development.sessions",
          parent: "people.development",
          label: "Sessions & calendar",
          icon: "squares-2x2",
          route: "/people/training/sessions",
          capability: "people.training.sessions.view",
          order: 50
        }
      ]
    }
  end
end
