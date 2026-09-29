defmodule Bilimbi.People.ReferenceData.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people" => "People domain capabilities"},
        capabilities: ["people.references.manage"]
      }
    }
  end
end
