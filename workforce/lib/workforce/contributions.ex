defmodule Bilimbi.People.Workforce.Contributions do
  @moduledoc false

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.workforce.working_statuses" => %{
            type: :array,
            scopes: [:company],
            default: ["probation", "active"],
            label: "Working employee statuses",
            help: "Employee statuses People treats as working staff for this company.",
            capability: "people.workforce.settings.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.workforce.settings.manage"]
      }
    }
  end
end
