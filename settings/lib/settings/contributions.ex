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
        }
      ]
    }
  end
end
