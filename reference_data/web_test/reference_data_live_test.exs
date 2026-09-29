defmodule BilimbiWeb.ReferenceDataLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures

  test "reference editor requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, "/people/companies/73/references")
  end

  test "reference editor refuses a same-tenant sibling company without tenant-wide reach",
       %{conn: conn} do
    UserFixtures.create_user_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "own_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73})
    grant_capabilities!(["people.references.manage"])

    {:ok, view, _html} = conn |> log_in_as() |> live("/people/companies/74/references")

    assert render(view) =~ "This company is unavailable in your tenant."
    refute has_element?(view, "form[phx-submit='create_entry']")
  end
end
