defmodule BilimbiWeb.LeaveLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.TestFixtures, as: LeaveFixtures

  test "leave pages require authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/leave/my")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/leave/policies")
  end

  describe "linked account" do
    setup do
      UserFixtures.create_user_tables!()
      SettingsFixtures.create_settings_table!()
      LeaveFixtures.create_leave_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
      {:ok, scope} = Tenancy.scope(41)
      :ok = Employee.ensure_system_types()

      {:ok, employee} =
        Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
      grant_capabilities!(["people.leave.self.view", "people.leave.policies.manage"])
      %{scope: scope}
    end

    test "self view shows an empty state before any leave type exists", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/my")
      assert has_element?(view, "#my-leave-no-types")
    end

    test "operator adds a type and version, grants, and the employee sees the balance", %{
      conn: conn
    } do
      conn = log_in_as(conn)
      {:ok, view, _} = live(conn, "/people/leave/policies")
      assert has_element?(view, "#leave-types-empty")
      assert has_element?(view, "#leave-policies-none")

      view
      |> form("#leave-type-form", type: %{code: "annual", name: "Annual leave", unit: "day"})
      |> render_submit()

      assert render(view) =~ "Leave type added."
      assert has_element?(view, "#leave-types", "Annual leave")

      year = Date.utc_today().year

      view
      |> form("#leave-policy-form", policy: %{effective_from: "#{year}-01-01", entitlement: "14"})
      |> render_submit()

      assert render(view) =~ "Policy version added."
      assert has_element?(view, "#leave-policy-versions", "14.00")

      view |> form("#leave-grant-form", leave_year: "#{year}") |> render_submit()
      assert render(view) =~ "1 entitlements granted; 0 were already granted."

      {:ok, my, _} = live(conn, "/people/leave/my")
      assert has_element?(my, "#my-leave-balances", "Annual leave")
      assert has_element?(my, "#my-leave-balances", "14.00")
    end

    test "the leave year is locked once balances exist", %{conn: conn, scope: scope} do
      {:ok, type} =
        Leave.create_type(scope, 73, %{code: "annual", name: "Annual", unit: "day", paid: true})

      {:ok, _} = Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2020-01-01], entitlement: 5})
      {:ok, _} = Leave.grant_entitlements(scope, 73, 2020)

      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/policies")
      view |> form("#leave-year-form", year_start_month: "4") |> render_submit()
      assert render(view) =~ "The leave year cannot change after balances have been recorded."
    end
  end
end
