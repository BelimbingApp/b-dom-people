defmodule BilimbiWeb.EmployeeWorkspaceLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.EmployeeWorkspace
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

      %{employee: employee, other: other, scope: scope}
    end

    # A direct deny overrides the earlier allow; the page stays connected.
    defp revoke!(scope, capability) do
      assert {:ok, :stored} =
               Authz.put_principal_capability(scope, 73, :user, 91, capability, false)
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

    test "a profile write after the manage grant is revoked is refused", %{
      conn: conn,
      employee: employee,
      scope: scope
    } do
      {:ok, view, _html} = conn |> log_in_as() |> live("/people/employees/#{employee.id}")
      assert has_element?(view, "form[phx-submit='save_profile']")

      revoke!(scope, "people.employees.manage")

      html =
        render_hook(view, "save_profile", %{"profile" => %{"work_location" => "After revocation"}})

      assert html =~ "You no longer have permission to change this employee"
      refute has_element?(view, "form[phx-submit='save_profile']")
      assert {:ok, nil} = EmployeeWorkspace.work_profile(actor_scope(scope), 73, employee.id)
    end

    test "employee actions refuse a revoked view grant while operation grants remain", %{
      conn: conn,
      employee: employee,
      scope: scope
    } do
      operator = actor_scope(scope)

      {:ok, request} =
        EmployeeWorkspace.request_change(operator, 73, employee.id, %{
          field: "full_name",
          proposed_value: "Updated Name",
          reason: "Correction"
        })

      {:ok, before_access} = EmployeeWorkspace.access(operator, 73, employee.id)

      views =
        for _ <- 1..4 do
          {:ok, view, _} = conn |> log_in_as() |> live("/people/employees/#{employee.id}")
          view
        end

      revoke!(scope, "people.employees.view")

      events = [
        {"save_profile", %{"profile" => %{"work_location" => "After revocation"}}},
        {"save_access", %{"access" => %{"portal_enabled" => "true"}}},
        {"request_change",
         %{
           "request" => %{
             "field" => "full_name",
             "proposed_value" => "Denied",
             "reason" => "Correction"
           }
         }},
        {"review_change", %{"id" => to_string(request.id), "decision" => "approved"}}
      ]

      for {view, {event, params}} <- Enum.zip(views, events) do
        assert {:error, {:redirect, %{to: "/dashboard"}}} = render_hook(view, event, params)
      end

      assert {:ok, :stored} =
               Authz.put_principal_capability(scope, 73, :user, 91, "people.employees.view", true)

      assert {:ok, nil} = EmployeeWorkspace.work_profile(operator, 73, employee.id)
      assert {:ok, ^before_access} = EmployeeWorkspace.access(operator, 73, employee.id)

      assert {:ok, [%{status: "pending"}]} =
               EmployeeWorkspace.change_requests(operator, 73, employee.id)
    end

    test "a review after the review grant is revoked is refused", %{
      conn: conn,
      employee: employee,
      scope: scope
    } do
      operator = actor_scope(scope)

      {:ok, request} =
        EmployeeWorkspace.request_change(operator, 73, employee.id, %{
          field: "full_name",
          proposed_value: "Updated Name",
          reason: "Correction"
        })

      {:ok, view, _html} = conn |> log_in_as() |> live("/people/employees/#{employee.id}")
      revoke!(scope, "people.employees.review")

      render_hook(view, "review_change", %{
        "id" => to_string(request.id),
        "decision" => "approved"
      })

      assert {:ok, [%{status: "pending"}]} =
               EmployeeWorkspace.change_requests(operator, 73, employee.id)
    end

    test "the directory fetches no new private facts after the view grant is revoked", %{
      conn: conn,
      employee: employee,
      scope: scope
    } do
      {:ok, view, html} = conn |> log_in_as() |> live("/people/employees")
      assert html =~ "First Employee"

      revoke!(scope, "people.employees.view")

      assert {:ok, _} =
               Employee.update_employee(scope, 73, employee.id, %{full_name: "Fresh private fact"})

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               render_hook(view, "filter", %{"search" => "Fresh", "status" => ""})
    end

    defp actor_scope(scope), do: Bilimbi.Base.Tenancy.Authentication.sign_in(scope, 91, 73)
  end
end
