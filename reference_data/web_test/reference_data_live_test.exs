defmodule BilimbiWeb.ReferenceDataLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.ReferenceData.TestFixtures, as: ReferenceFixtures

  test "reference editor requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, "/people/companies/73/references")
  end

  describe "authorized operator" do
    setup do
      UserFixtures.create_user_tables!()
      ReferenceFixtures.create_reference_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "own_company"})
      CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      grant_capabilities!(["people.references.manage"])
      :ok
    end

    test "manages references for their own company", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_as() |> live("/people/companies/73/references")

      assert render(view) =~ "No references have been added for this company."

      view
      |> form("form[phx-submit='create_entry']",
        entry: %{kind: "category", code: "one", label: "First value"}
      )
      |> render_submit()

      assert render(view) =~ "First value"
    end

    test "refuses a same-tenant sibling company without tenant-wide reach", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_as() |> live("/people/companies/74/references")

      assert render(view) =~ "This company is unavailable in your tenant."
      refute has_element?(view, "form[phx-submit='create_entry']")
    end
  end
end
