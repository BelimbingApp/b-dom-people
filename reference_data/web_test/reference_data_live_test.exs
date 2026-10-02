defmodule BilimbiWeb.ReferenceDataLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.ReferenceData.TestFixtures, as: ReferenceFixtures

  test "reference editor requires authentication", %{conn: conn} do
    for route <- ["/people/references", "/people/companies/73/references"] do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, route)
    end
  end

  describe "authorized operator" do
    setup do
      UserFixtures.create_user_tables!()
      ReferenceFixtures.create_reference_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})

      CompanyFixtures.insert_company!(%{
        id: 73,
        tenant_id: 41,
        code: "own_company",
        name: "Workforce company"
      })

      CompanyFixtures.insert_company!(%{
        id: 74,
        tenant_id: 41,
        code: "sibling_company",
        name: "Sibling workforce company"
      })

      UserFixtures.insert_user!(%{
        id: 91,
        company_id: 73,
        name: "Login actor",
        email: "actor@example.test"
      })

      grant_capabilities!(["people.references.manage"])
      :ok
    end

    test "entry offers only authorized companies and opens the explicit route", %{conn: conn} do
      {:ok, view, html} = conn |> log_in_as() |> live("/people/references")
      assert html =~ ~s(href="/people/references")
      assert has_element?(view, "#reference-company option[value='73']")
      refute has_element?(view, "#reference-company option[value='74']")
      refute has_element?(view, "form[phx-submit='create_entry']")
      view |> form("#reference-company-picker", company_id: "73") |> render_submit()
      assert_redirect(view, "/people/companies/73/references")
    end

    test "forged sibling selection refuses navigation", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/references")
      assert render_hook(view, "select_company", %{"company_id" => "74"}) =~ "unavailable to you"
      refute has_element?(view, "form[phx-submit='create_entry']")
    end

    test "revocation empties the chooser and refuses selection", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/references")
      revoke!("people.references.manage")

      assert render_hook(view, "select_company", %{"company_id" => "73"}) =~
               "No companies available"

      refute has_element?(view, "#reference-company-picker")
      assert {:error, _} = conn |> log_in_as() |> live("/people/references")
    end

    test "revocation refuses every write on an open page", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/companies/73/references")
      {:ok, scope} = Bilimbi.Base.Tenancy.scope(41)

      {:ok, entry} =
        Bilimbi.People.ReferenceData.create_entry(scope, 73, %{
          kind: "category",
          code: "existing",
          label: "Existing value"
        })

      revoke!("people.references.manage")

      for {event, params} <- [
            {"create_entry",
             %{"entry" => %{"kind" => "category", "code" => "refused", "label" => "Refused"}}},
            {"add_alias",
             %{"alias" => %{"entry_id" => to_string(entry.id), "label" => "Refused"}}},
            {"create_exception",
             %{"exception" => %{"on_date" => "2026-10-03", "label" => "Refused"}}}
          ] do
        assert render_hook(view, event, params) =~ "cannot change"
      end

      assert {:ok, [%{id: id}]} = Bilimbi.People.ReferenceData.list_entries(scope, 73)
      assert id == entry.id
      assert {:ok, []} = Bilimbi.People.ReferenceData.list_aliases(scope, 73)
      assert {:ok, []} = Bilimbi.People.ReferenceData.list_calendar_exceptions(scope, 73)
    end

    test "revoked tenant reach refuses a sibling write", %{conn: conn} do
      grant_capabilities!(["admin.company.tenant-wide.manage"])
      {:ok, view, _} = conn |> log_in_as() |> live("/people/companies/74/references")
      assert has_element?(view, "form[phx-submit='create_entry']")
      revoke!("admin.company.tenant-wide.manage")

      assert render_hook(view, "create_entry", %{
               "entry" => %{"kind" => "category", "code" => "refused", "label" => "Refused"}
             }) =~ "cannot change"

      {:ok, scope} = Bilimbi.Base.Tenancy.scope(41)
      assert {:ok, []} = Bilimbi.People.ReferenceData.list_entries(scope, 74)
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

  defp revoke!(capability) do
    {:ok, scope} = Bilimbi.Base.Tenancy.scope(41)

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(scope, 73, :user, 91, capability, false)
  end
end
