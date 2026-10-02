defmodule Bilimbi.People.Settings.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      menu: [
        %{
          id: "people",
          label: "People",
          icon: "users",
          parent: nil,
          route: nil,
          capability: nil,
          order: 50
        },
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
          id: "people.team",
          label: "Team",
          parent: "people",
          route: nil,
          capability: nil,
          order: 20
        },
        %{
          id: "people.time_and_expenses",
          label: "Time and expenses",
          parent: "people",
          route: nil,
          capability: nil,
          order: 30
        },
        %{
          id: "people.development",
          label: "Development",
          parent: "people",
          route: nil,
          capability: nil,
          order: 40
        },
        %{
          id: "people.reports",
          label: "Reports",
          parent: "people",
          route: nil,
          capability: nil,
          order: 80
        },
        %{
          id: "people.settings",
          label: "Settings",
          icon: "cog-6-tooth",
          parent: "people",
          route: nil,
          capability: nil,
          order: 90
        }
      ]
    }
  end
end
