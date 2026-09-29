defmodule Bilimbi.People.ReferenceData.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.references.manage"]
      }
    }
  end
end
