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
      # Direct routes remain available for acceptance; rollout navigation stays hidden.
      menu: []
    }
  end
end
