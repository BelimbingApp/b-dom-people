defmodule Bilimbi.People.Training.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities:
          ~w(people.training.courses.view people.training.courses.manage people.training.sessions.view people.training.sessions.manage people.training.records.view people.training.records.manage people.training.evidence.manage people.training.retention.manage)
      },
      menu: []
    }
  end
end
