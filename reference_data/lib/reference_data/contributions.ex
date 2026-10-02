defmodule Bilimbi.People.ReferenceData.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      menu: [
        %{
          id: "people.settings.references",
          label: "People references",
          icon: "clipboard-document-list",
          parent: "people.settings",
          route: "/people/references",
          capability: "people.references.manage",
          order: 10
        }
      ],
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.references.manage"]
      }
    }
  end
end
