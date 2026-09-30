defmodule Bilimbi.People.Payroll.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.payroll.country" => %{
            type: :string,
            scopes: [:company],
            default: "",
            label: "Payroll country",
            help: "Operator-selected jurisdiction identifier; no statutory pack is activated.",
            capability: "people.payroll.manage"
          },
          "people.payroll.currencies" => %{
            type: :array,
            scopes: [:company],
            default: [],
            label: "Payroll currencies",
            help: "Explicit currency codes accepted for new pay items and runs.",
            capability: "people.payroll.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.payroll.view", "people.payroll.manage"],
        roles: %{
          "tenant_owner" => %{capabilities: ["people.payroll.view", "people.payroll.manage"]}
        }
      },
      menu: []
    }
  end
end
