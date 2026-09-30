defmodule Bilimbi.People.Claims.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.claims.currencies" => %{
            type: :array,
            scopes: [:company],
            default: [],
            label: "Claim currencies",
            help: "ISO 4217 currency codes this company accepts on claims.",
            capability: "people.claims.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: ["people.claims.submit", "people.claims.manage"],
        roles: %{
          "tenant_owner" => %{
            capabilities: ["people.claims.submit", "people.claims.manage"]
          }
        }
      },
      menu: [
        %{
          id: "people.my_work.claims",
          label: "My claims",
          parent: "people.my_work",
          route: "/people/claims",
          capability: "people.claims.submit",
          order: 30
        },
        %{
          id: "people.settings.claim_policies",
          label: "Claim policies",
          parent: "people.settings",
          route: "/people/claims/setup",
          capability: "people.claims.manage",
          order: 40
        }
      ]
    }
  end
end
