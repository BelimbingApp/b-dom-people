defmodule BilimbiWeb.EmployeeWorkspaceLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.EmployeeWorkspace.TestFixtures, as: WorkspaceFixtures

  test "People employee route requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/employees")
  end

  describe "authorized actor" do
    setup do
      UserFixtures.create_user_tables!()
      :ok = Employee.ensure_system_types()
      WorkspaceFixtures.create_workspace_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "own_company"})
      CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "other_company"})
      UserFixtures.insert_user!(%{id: 91, company_id: 73})
      {:ok, scope} = Tenancy.scope(41)

      {:ok, employee} =
        Employee.create_employee(scope, 73, %{
          employee_number: "EMP-01",
          full_name: "First Employee",
          employee_type: "full_time",
          status: "active"
        })

      {:ok, other} =
        Employee.create_employee(scope, 74, %{
          employee_number: "EMP-02",
          full_name: "Other Employee",
          employee_type: "full_time",
          status: "active"
        })

      grant_capabilities!([
        "people.employees.view",
        "people.employees.manage",
        "people.employees.review"
      ])

      %{employee: employee, other: other}
    end

    test "lists only the actor company and saves a private view", %{conn: conn} do
      {:ok, view, html} = conn |> log_in_as() |> live("/people/employees")
      assert html =~ "First Employee"
      refute html =~ "Other Employee"

      view
      |> form("form[phx-submit='save_view']", view: %{name: "My view"})
      |> render_submit()

      assert render(view) =~ "My view"
    end

    test "shows People facts, accepts changes, and refuses sibling employee", %{
      conn: conn,
      employee: employee,
      other: other
    } do
      logged_in = log_in_as(conn)
      {:ok, view, html} = live(logged_in, "/people/employees/#{employee.id}")
      assert html =~ "No profile changes have been requested."

      view
      |> form("form[phx-submit='save_profile']",
        profile: %{
          work_location: "Office",
          work_arrangement: "Flexible",
          notes: "On site"
        }
      )
      |> render_submit()

      assert render(view) =~ "Office"

      view
      |> form("form[phx-submit='request_change']",
        request: %{
          field: "full_name",
          proposed_value: "Updated Name",
          reason: "Correction"
        }
      )
      |> render_submit()

      assert render(view) =~ "Updated Name"
      {:ok, denied, _} = live(logged_in, "/people/employees/#{other.id}")
      assert render(denied) =~ "This employee is unavailable in your company."
      refute has_element?(denied, "form[phx-submit='save_profile']")
    end
  end
end
