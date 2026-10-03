defmodule Bilimbi.People.Workforce.AuthorizationFixtures do
  @moduledoc false
  # Shared by People module tests whose facades authorize every operation
  # through `Bilimbi.People.Workforce.Authorization`.
  #
  # A facade refuses a system scope, so a test performs its writes with a
  # scope signed in as a user who holds the capabilities. That needs the
  # Authz tables (`Bilimbi.Base.Authz.TestFixtures.create_authz_tables!/0`),
  # the users table (`Bilimbi.Core.User.TestFixtures.create_user_tables!/0`),
  # a registry snapshot that knows the module's capabilities
  # (`install_snapshot!/2` with `authz_consumer!/1`), an inserted user, and
  # `sign_in!/4`.

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator, as: AuthzValidator
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope

  @doc """
  The validated Authz consumer for these People contribution modules, over
  the platform contributions a People capability check needs.
  """
  def authz_consumer!(contribution_modules) when is_list(contribution_modules) do
    AuthzValidator.validate_contributions!(
      platform_entries() ++ Enum.map(contribution_modules, &people_entry/1)
    )
  end

  @doc """
  Installs a registry snapshot carrying these consumers over the registry's
  own empty shape, so a consumer added later keeps its correct empty value.
  """
  def install_snapshot!(fingerprint, consumers)
      when is_binary(fingerprint) and is_map(consumers) do
    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: fingerprint,
      consumers: Map.merge(ContributionRegistry.build!([]).consumers, consumers)
    })
  end

  @doc "Grants direct capabilities to a user in a company."
  def grant!(%Scope{} = scope, company_id, user_id, capabilities) do
    Enum.each(List.wrap(capabilities), fn capability ->
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company_id, :user, user_id, capability, true)
    end)

    :ok
  end

  @doc "Denies one capability directly, which overrides any allow for the user."
  def revoke!(%Scope{} = scope, company_id, user_id, capability) do
    {:ok, :stored} =
      Authz.put_principal_capability(scope, company_id, :user, user_id, capability, false)

    :ok
  end

  @doc """
  A scope performed by the signed-in user, sealed as the authentication edge
  seals it. Tests are the only module code allowed to call the edge.
  """
  def sign_in(%Scope{} = scope, user_id, company_id),
    do: Authentication.sign_in(scope, user_id, company_id)

  @doc "Grants the capabilities to the user in the company and signs them in."
  def sign_in!(%Scope{} = scope, company_id, user_id, capabilities) do
    :ok = grant!(scope, company_id, user_id, capabilities)
    sign_in(scope, user_id, company_id)
  end

  defp platform_entries do
    [
      %{
        descriptor: %{id: "base/authz", otp_app: :bilimbi_base_authz},
        payload: Bilimbi.Base.Authz.Contributions.contributions()[:authz]
      },
      %{
        descriptor: %{id: "core/company", otp_app: :bilimbi_core_company},
        payload: Bilimbi.Core.Company.Contributions.contributions()[:authz]
      },
      # Base Tiling declares the publish verb in a composed application; it is
      # outside a People module's test closure, so the verb is declared here.
      %{
        descriptor: %{id: "base/tiling", otp_app: :bilimbi_base_tiling},
        payload: %{domains: %{}, verbs: ["publish"], capabilities: [], roles: %{}}
      }
    ]
  end

  # `Bilimbi.People.Claims.Contributions` is module `people/claims` in OTP
  # application `:bilimbi_people_claims`.
  defp people_entry(module) when is_atom(module) do
    ["Bilimbi", "People", name, "Contributions"] = Module.split(module)
    id = Macro.underscore(name)

    %{
      descriptor: %{id: "people/#{id}", otp_app: String.to_atom("bilimbi_people_#{id}")},
      payload: module.contributions().authz
    }
  end
end
