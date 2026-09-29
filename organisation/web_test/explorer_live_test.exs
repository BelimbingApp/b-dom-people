defmodule Bilimbi.People.Organisation.Web.ExplorerLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Organisation
  alias Bilimbi.People.Organisation.TestFixtures

  setup do
    UserFixtures.create_user_tables!()
    TestFixtures.create_position_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "the authorised explorer shows empty state and company-scoped positions", %{
    conn: conn,
    scope: scope
  } do
    grant_capabilities!("people.organisation.view")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/organisation")
    assert has_element?(view, "#organisation-empty")

    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-1"})

    {:ok, _} =
      Organisation.record_version(scope, 73, position.id, %{
        version: 1,
        title: "Position Alpha",
        effective_from: ~D[2026-01-01]
      })

    assert render_patch(view, ~p"/people/organisation?as_of=2026-09-30") =~ "Position Alpha"
    refute render_patch(view, ~p"/people/organisation?company_id=74") =~ "Position Alpha"
  end

  test "route refuses an actor without the capability", %{conn: conn} do
    assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live(~p"/people/organisation")
  end
end
