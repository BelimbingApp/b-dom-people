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
        capabilities: [
          "people.payroll.view",
          "people.payroll.manage",
          "people.payroll.approve",
          "people.payroll.attendance-mappings.manage"
        ],
        roles: %{
          "tenant_owner" => %{
            capabilities: [
              "people.payroll.view",
              "people.payroll.manage",
              "people.payroll.approve"
            ]
          }
        }
      },
      menu: [
        %{
          id: "people.payroll.runs",
          label: "Runs",
          parent: "people.payroll",
          route: "/people/payroll/runs",
          capability: "people.payroll.view",
          icon: "circle-stack",
          order: 10
        },
        %{
          id: "people.payroll.mappings",
          label: "Pay-item mappings",
          parent: "people.payroll",
          route: "/people/payroll/setup/mappings",
          capability: "people.payroll.view",
          icon: "squares-2x2",
          order: 20
        },
        %{
          id: "people.settings.payroll_setup",
          label: "Payroll setup",
          parent: "people.settings",
          route: "/people/payroll/setup",
          capability: "people.payroll.view",
          icon: "cog-6-tooth",
          order: 70
        }
      ]
    }
  end
end
