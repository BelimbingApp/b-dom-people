defmodule BilimbiWeb.ClaimsLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Claims
  alias Bilimbi.People.Claims.TestFixtures, as: ClaimFixtures

  test "claim routes require authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/claims")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/claims/setup")
  end

  describe "signed-in actor" do
    setup do
      UserFixtures.create_user_tables!()
      ClaimFixtures.create_claim_tables!()
      :ok = Employee.ensure_system_types()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "own_company"})
      CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "other_company"})
      {:ok, scope} = Tenancy.scope(41)

      {:ok, employee} =
        Employee.create_employee(scope, 73, %{
          employee_number: "EMP-01",
          full_name: "First Employee",
          employee_type: "full_time",
          status: "active"
        })

      %{scope: scope, employee: employee}
    end

    test "an actor without a linked employee sees an unavailable state", %{conn: conn} do
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      grant_capabilities!(["people.claims.submit"])

      {:ok, view, _html} = conn |> log_in_as() |> live("/people/claims")

      assert has_element?(view, "#my-claims-unavailable")
      refute has_element?(view, "#my-claims-form")
    end

    test "an operator opens a claim type and the employee submits and withdraws", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
      grant_capabilities!(["people.claims.submit", "people.claims.manage"])
      logged_in = log_in_as(conn)

      {:ok, mine, _html} = live(logged_in, "/people/claims")
      assert has_element?(mine, "#my-claims-no-types")
      assert has_element?(mine, "#my-claims-empty")

      {:ok, setup, _html} = live(logged_in, "/people/claims/setup")
      assert has_element?(setup, "#claim-categories-empty")
      refute has_element?(setup, "#claim-policy-form")

      setup |> form("#claim-currencies-form", %{currencies: "aaa, BBB"}) |> render_submit()
      assert {:ok, ["AAA", "BBB"]} = Claims.currencies(scope, 73)

      setup
      |> form("#claim-category-form", category: %{code: "travel", name: "Travel"})
      |> render_submit()

      setup
      |> form("#claim-type-form",
        claim_type: %{code: "fuel", name: "Fuel", receipt_requirement: "always"}
      )
      |> render_submit()

      setup
      |> form("#claim-policy-form",
        policy: %{effective_from: "2026-01-01", currency: "AAA", per_claim_limit: "100"}
      )
      |> render_submit()

      assert has_element?(setup, "#claim-policies-table")

      {:ok, mine, _html} = live(logged_in, "/people/claims")
      assert render(mine) =~ "Fuel"

      claim = %{incurred_on: "2026-03-10", amount: "40", currency: "AAA"}

      assert mine |> form("#my-claims-form", claim: claim) |> render_submit() =~
               "This claim needs a receipt number."

      mine
      |> form("#my-claims-form", claim: Map.put(claim, :receipt_number, "R-1"))
      |> render_submit()

      assert has_element?(mine, "#my-claims-table", "R-1")

      assert render(mine) =~ "Claim submitted."

      duplicate_prompt =
        mine
        |> form("#my-claims-form", claim: Map.put(claim, :receipt_number, "R-2"))
        |> render_submit()

      assert duplicate_prompt =~ "Confirm it is a separate expense"
      refute duplicate_prompt =~ "Claim submitted."
      assert has_element?(mine, "#my-claims-form input[name='claim[incurred_on]'][value='2026-03-10']")
      assert has_element?(mine, "#my-claims-form input[name='claim[amount]'][value='40']")
      assert has_element?(mine, "#my-claims-form input[name='claim[receipt_number]'][value='R-2']")
      assert has_element?(mine, "#my-claims-form option[value='AAA'][selected]")

      mine
      |> form("#my-claims-form",
        claim: claim |> Map.put(:receipt_number, "R-2") |> Map.put(:confirm_duplicate, "true")
      )
      |> render_submit()

      assert {:ok, [second, first]} = Claims.employee_requests(scope, 73, employee.id)
      assert second.duplicate_confirmed

      mine |> element("#claim-#{first.id} button", "Withdraw") |> render_click()
      assert {:ok, [_, %{status: "withdrawn"}]} = Claims.employee_requests(scope, 73, employee.id)
    end

    test "claim setup requires the manage capability", %{conn: conn} do
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      grant_capabilities!(["people.claims.submit"])

      assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live("/people/claims/setup")
    end
  end
end
