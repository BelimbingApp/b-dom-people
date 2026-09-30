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
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/claims/operations")
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

      assert has_element?(
               mine,
               "#my-claims-form input[name='claim[incurred_on]'][value='2026-03-10']"
             )

      assert has_element?(mine, "#my-claims-form input[name='claim[amount]'][value='40']")

      assert has_element?(
               mine,
               "#my-claims-form input[name='claim[receipt_number]'][value='R-2']"
             )

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

    test "operations need the approve capability", %{conn: conn} do
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      grant_capabilities!(["people.claims.submit"])

      assert {:error, {_kind, _redirect}} =
               conn |> log_in_as() |> live("/people/claims/operations")
    end

    test "an approver decides, hands off, exports, and reimburses claims", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
      UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "approver@example.com"})
      grant_capabilities!(["people.claims.approve"], user_id: 92)
      grant_capabilities!(["people.claims.approve", "people.claims.submit"], user_id: 91)

      {:ok, ["AAA"]} = Claims.put_currencies(scope, 73, ["AAA"])
      {:ok, category} = Claims.create_category(scope, 73, %{"code" => "c", "name" => "Travel"})

      {:ok, claim_type} =
        Claims.create_claim_type(scope, 73, %{
          "category_id" => category.id,
          "code" => "fuel",
          "name" => "Fuel",
          "receipt_requirement" => "never"
        })

      {:ok, _} =
        Claims.create_policy(scope, 73, %{
          "claim_type_id" => claim_type.id,
          "effective_from" => "2026-01-01",
          "currency" => "AAA"
        })

      submit = fn attrs ->
        {:ok, request} =
          Claims.submit_request(
            scope,
            73,
            employee.id,
            91,
            Map.merge(
              %{
                claim_type_id: claim_type.id,
                incurred_on: "2026-03-10",
                amount: "40",
                currency: "AAA"
              },
              attrs
            )
          )

        request
      end

      first = submit.(%{})
      second = submit.(%{amount: "25", receipt_number: "R-2"})
      approver = log_in_as(conn, %{"user_id" => 92, "company_id" => 73})

      {:ok, view, _html} = live(approver, "/people/claims/operations")
      assert has_element?(view, "#claim-row-#{first.id}", "First Employee")

      # Rejection needs a reason before anything is held for confirmation.
      view
      |> form("#decide-#{first.id}", %{approved_amount: "", decision_reason: ""})
      |> render_submit(%{decision: "reject"})

      refute has_element?(view, "#claim-operations-confirm")
      assert render(view) =~ "Enter a reason before rejecting a claim."

      view
      |> form("#decide-#{first.id}", %{approved_amount: "", decision_reason: "Not covered"})
      |> render_submit(%{decision: "reject"})

      assert has_element?(view, "#claim-operations-confirm")
      render_click(view, "confirm")
      assert render(view) =~ "Claim rejected."
      refute has_element?(view, "#claim-row-#{first.id}")

      view
      |> form("#decide-#{second.id}", %{approved_amount: "20", decision_reason: ""})
      |> render_submit(%{decision: "approve"})

      render_click(view, "confirm")
      assert render(view) =~ "Enter a reason for this decision."

      view
      |> form("#decide-#{second.id}", %{approved_amount: "20", decision_reason: "Partly covered"})
      |> render_submit(%{decision: "approve"})

      render_click(view, "confirm")
      assert render(view) =~ "Claim approved."

      {:ok, view, _html} = live(approver, "/people/claims/operations?tab=approved")
      assert has_element?(view, "#claim-row-#{second.id}")

      # Without the reimbursement capability nothing can be handed off.
      refute has_element?(view, "#claim-handoff-waiting")
      refute has_element?(view, "#reimburse-#{second.id}")
      render_click(view, "handoff", %{"currency" => "AAA"})
      refute has_element?(view, "#claim-operations-confirm")
      assert {:ok, []} = Claims.handoff_batches(scope, 73)

      grant_capabilities!(["people.claims.reimburse"], user_id: 92)
      {:ok, view, _html} = live(approver, "/people/claims/operations?tab=approved")
      assert has_element?(view, "#claim-handoff-waiting")
      render_click(view, "handoff", %{"currency" => "AAA"})
      render_click(view, "confirm")
      assert render(view) =~ "Hand-off batch created."

      {:ok, view, _html} = live(approver, "/people/claims/operations?tab=batches")
      assert {:ok, [%{id: batch_id}]} = Claims.handoff_batches(scope, 73)
      assert has_element?(view, "#claim-batch-#{batch_id}", "1 claims")

      view |> element("#claim-batch-#{batch_id} button", "Prepare CSV") |> render_click()

      assert has_element?(
               view,
               "#claim-batch-download-#{batch_id}[download='claim-handoff-#{batch_id}.csv']"
             )

      assert has_element?(view, "#claim-batch-download-#{batch_id}[href^='data:text/csv']")

      view
      |> form("#reimburse-batch-#{batch_id}", %{payment_reference: "RUN-1"})
      |> render_submit()

      render_click(view, "confirm")
      assert render(view) =~ "Batch claims marked reimbursed."

      {:ok, view, _html} = live(approver, "/people/claims/operations?tab=reimbursed")
      assert has_element?(view, "#claim-row-#{second.id}", "RUN-1")

      # The claimant may open the queue but never decides its own claim.
      third = submit.(%{amount: "9", incurred_on: "2026-03-11"})
      {:ok, own, _html} = live(log_in_as(conn), "/people/claims/operations")

      own
      |> form("#decide-#{third.id}", %{approved_amount: "", decision_reason: ""})
      |> render_submit(%{decision: "approve"})

      render_click(own, "confirm")
      assert render(own) =~ "You cannot act on your own claim."

      {:ok, mine, _html} = live(log_in_as(conn), "/people/claims")
      assert has_element?(mine, "#claim-#{second.id}", "Approved 20.00 AAA")
      assert has_element?(mine, "#claim-#{first.id}", "Not covered")
    end

    test "an operator assigns an assigned-only claim type to an employee", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
      grant_capabilities!(["people.claims.submit", "people.claims.manage"])
      logged_in = log_in_as(conn)

      {:ok, ["AAA"]} = Claims.put_currencies(scope, 73, ["AAA"])
      {:ok, category} = Claims.create_category(scope, 73, %{"code" => "c", "name" => "Travel"})

      {:ok, setup, _html} = live(logged_in, "/people/claims/setup")
      assert has_element?(setup, "#claim-assignments-empty")

      setup
      |> form("#claim-type-form",
        claim_type: %{
          category_id: category.id,
          code: "fuel",
          name: "Fuel",
          receipt_requirement: "never",
          eligibility: "assigned_only"
        }
      )
      |> render_submit()

      assert render(setup) =~ "Assigned employees only"
      assert {:ok, [%{id: type_id}]} = Claims.claim_types(scope, 73)

      {:ok, _} =
        Claims.create_policy(scope, 73, %{
          "claim_type_id" => type_id,
          "effective_from" => "2026-01-01",
          "currency" => "AAA"
        })

      setup
      |> form("#claim-assignment-form",
        assignment: %{code: "field", name: "Field staff", effective_from: "2026-01-01"}
      )
      |> render_submit()

      assert {:ok, [%{id: assignment_id}]} = Claims.assignments(scope, 73)

      {:ok, mine, _html} = live(logged_in, "/people/claims")
      assert has_element?(mine, "#my-claims-no-types")

      {:ok, setup, _html} = live(logged_in, "/people/claims/setup")

      setup
      |> form("#claim-assignment-members-#{assignment_id}", %{
        claim_type_ids: [Integer.to_string(type_id)],
        employee_ids: [Integer.to_string(employee.id)]
      })
      |> render_submit()

      assert {:ok, [%{claim_type_ids: [^type_id], employee_ids: [employee_id]}]} =
               Claims.assignments(scope, 73)

      assert employee_id == employee.id

      {:ok, mine, _html} = live(logged_in, "/people/claims")
      assert has_element?(mine, "#my-claims-open-types", "Fuel")
    end

    test "claim setup requires the manage capability", %{conn: conn} do
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      grant_capabilities!(["people.claims.submit"])

      assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live("/people/claims/setup")
    end
  end
end
