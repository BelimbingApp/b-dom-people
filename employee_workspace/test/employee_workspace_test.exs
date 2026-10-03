defmodule Bilimbi.People.EmployeeWorkspaceTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.EmployeeWorkspace
  alias Bilimbi.People.EmployeeWorkspace.Contributions
  alias Bilimbi.People.EmployeeWorkspace.TestFixtures, as: WorkspaceFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures

  @view "people.employees.view"
  @manage "people.employees.manage"
  @review "people.employees.review"
  @all [@view, @manage, @review]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    AuthorizationFixtures.install_snapshot!("people-employee-workspace-test", %{
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    :ok = Employee.ensure_system_types()
    WorkspaceFixtures.create_workspace_tables!()
    CompanyFixtures.insert_tenant!()
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!()
    CompanyFixtures.insert_company!(%{id: 74, code: "second_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)

    {:ok, employee} =
      Employee.create_employee(first, 73, %{
        employee_number: "EMP-01",
        full_name: "First Employee",
        employee_type: "full_time",
        status: "active"
      })

    # The operator holds every workbench capability in company 73; the
    # reviewer holds view and review only; the outsider belongs to tenant 42.
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Reviewer", email: "r@example.com"})
    UserFixtures.insert_user!(%{id: 95, company_id: 75, name: "Outsider", email: "o@example.com"})
    operator = AuthorizationFixtures.sign_in!(first, 73, 91, @all)
    reviewer = AuthorizationFixtures.sign_in!(first, 73, 92, [@view, @review])
    outsider = AuthorizationFixtures.sign_in!(second, 75, 95, @all)

    %{
      first: first,
      second: second,
      employee: employee,
      operator: operator,
      reviewer: reviewer,
      outsider: outsider
    }
  end

  test "keeps Core Employee master separate and refuses other company axes", %{
    first: first,
    operator: operator,
    outsider: outsider,
    employee: employee
  } do
    assert {:ok, [%{id: id}]} = EmployeeWorkspace.employees(operator, 73)
    assert id == employee.id
    # A sibling company is outside the operator's reach; another tenant's
    # actor cannot see the company at all; a system scope names nobody.
    assert {:error, :unauthorized} = EmployeeWorkspace.work_profile(operator, 74, employee.id)
    assert {:error, :not_found} = EmployeeWorkspace.work_profile(outsider, 73, employee.id)
    assert {:error, :unauthorized} = EmployeeWorkspace.work_profile(first, 73, employee.id)

    assert {:error, :unauthorized} =
             EmployeeWorkspace.put_work_profile(operator, 74, employee.id, %{
               work_location: "Other"
             })

    assert {:ok, profile} =
             EmployeeWorkspace.put_work_profile(operator, 73, employee.id, %{
               work_location: "Office",
               work_arrangement: "Flexible"
             })

    assert profile.work_location == "Office"

    assert {:ok, %{work_location: "Office"}} =
             EmployeeWorkspace.work_profile(operator, 73, employee.id)

    assert {:ok, core} = Employee.get_employee(first, 73, employee.id)
    assert core.full_name == "First Employee"
    assert {:error, :unauthorized} = EmployeeWorkspace.employees(operator, 74)
  end

  test "every operation needs its own capability now, not the one proven earlier", %{
    first: first,
    operator: operator,
    reviewer: reviewer,
    employee: employee
  } do
    assert {:error, :unauthorized} =
             EmployeeWorkspace.put_work_profile(reviewer, 73, employee.id, %{work_location: "X"})

    assert {:error, :unauthorized} =
             EmployeeWorkspace.put_access(reviewer, 73, employee.id, %{portal_enabled: true})

    assert {:error, :unauthorized} =
             EmployeeWorkspace.request_change(reviewer, 73, employee.id, %{
               field: "full_name",
               proposed_value: "Other",
               reason: "Correction"
             })

    assert {:ok, request} =
             EmployeeWorkspace.request_change(operator, 73, employee.id, %{
               field: "full_name",
               proposed_value: "Updated Name",
               reason: "Correction"
             })

    assert request.requested_by_actor_id == 91

    # The operator's manage grant is revoked while their session continues:
    # the next write is refused and nothing changed.
    :ok = AuthorizationFixtures.revoke!(first, 73, 91, @manage)

    assert {:error, :unauthorized} =
             EmployeeWorkspace.put_work_profile(operator, 73, employee.id, %{
               work_location: "After revocation"
             })

    assert {:ok, nil} = EmployeeWorkspace.work_profile(operator, 73, employee.id)

    :ok = AuthorizationFixtures.revoke!(first, 73, 91, @view)
    assert {:error, :unauthorized} = EmployeeWorkspace.employees(operator, 73)
    assert {:error, :unauthorized} = EmployeeWorkspace.change_requests(operator, 73, employee.id)
    assert {:ok, [%{id: _}]} = EmployeeWorkspace.change_requests(reviewer, 73, employee.id)
  end

  test "access is only an eligibility fact and change review is one-time", %{
    first: first,
    operator: operator,
    reviewer: reviewer,
    employee: employee
  } do
    assert {:ok, nil} = EmployeeWorkspace.access(operator, 73, employee.id)

    assert {:ok, %{portal_enabled: true}} =
             EmployeeWorkspace.put_access(operator, 73, employee.id, %{
               portal_enabled: true,
               reason: "Operator decision"
             })

    assert {:ok, request} =
             EmployeeWorkspace.request_change(operator, 73, employee.id, %{
               field: "full_name",
               proposed_value: "Updated Name",
               reason: "Correction"
             })

    assert request.status == "pending"

    # Without the review grant the operator cannot decide; the reviewer is
    # the actor recorded.
    :ok = AuthorizationFixtures.revoke!(first, 73, 91, @review)

    assert {:error, :unauthorized} =
             EmployeeWorkspace.review_change(operator, 73, employee.id, request.id, "approved")

    assert {:ok, reviewed} =
             EmployeeWorkspace.review_change(reviewer, 73, employee.id, request.id, "approved")

    assert reviewed.status == "approved"
    assert reviewed.reviewed_by_actor_id == 92

    assert {:error, :already_reviewed} =
             EmployeeWorkspace.review_change(reviewer, 73, employee.id, request.id, "rejected")

    assert {:ok, core} = Employee.get_employee(first, 73, employee.id)
    assert core.full_name == "First Employee"
  end

  test "saved views are private to the signed-in actor and company", %{
    first: first,
    operator: operator,
    reviewer: reviewer
  } do
    assert {:ok, view} =
             EmployeeWorkspace.save_view(operator, 73, %{
               name: "Current",
               search: "first",
               status: "active"
             })

    assert {:ok, [%{name: "Current"}]} = EmployeeWorkspace.saved_views(operator, 73)
    assert {:ok, []} = EmployeeWorkspace.saved_views(reviewer, 73)
    assert {:error, :unauthorized} = EmployeeWorkspace.saved_views(operator, 74)
    assert {:error, :unauthorized} = EmployeeWorkspace.saved_views(first, 73)
    assert {:error, :not_found} = EmployeeWorkspace.delete_view(reviewer, 73, view.id)
    assert {:ok, :deleted} = EmployeeWorkspace.delete_view(operator, 73, view.id)
    assert {:ok, []} = EmployeeWorkspace.saved_views(operator, 73)
  end

  test "follows Core company liveness: non-active companies stay usable, deleted stay unavailable",
       %{first: first} do
    CompanyFixtures.insert_company!(%{id: 76, code: "pending_company", status: "pending"})

    {:ok, employee} =
      Employee.create_employee(first, 76, %{
        employee_number: "EMP-76",
        full_name: "Pending Employee",
        employee_type: "full_time",
        status: "active"
      })

    UserFixtures.insert_user!(%{id: 96, company_id: 76, name: "Pending", email: "p@example.com"})
    scope = AuthorizationFixtures.sign_in!(first, 76, 96, @all)

    assert {:ok, [%{id: id}]} = EmployeeWorkspace.employees(scope, 76)
    assert id == employee.id

    assert {:ok, _} =
             EmployeeWorkspace.put_work_profile(scope, 76, employee.id, %{work_location: "Hub"})

    assert {:ok, %{work_location: "Hub"}} = EmployeeWorkspace.work_profile(scope, 76, employee.id)
    assert {:ok, nil} = EmployeeWorkspace.access(scope, 76, employee.id)
    assert {:ok, []} = EmployeeWorkspace.change_requests(scope, 76, employee.id)
    assert {:ok, _} = EmployeeWorkspace.save_view(scope, 76, %{name: "Pending"})
    assert {:ok, [%{name: "Pending"}]} = EmployeeWorkspace.saved_views(scope, 76)

    CompanyFixtures.insert_company!(%{
      id: 77,
      code: "deleted_company",
      deleted_at: DateTime.utc_now()
    })

    assert {:error, :not_found} = EmployeeWorkspace.employees(scope, 77)
    assert {:error, :not_found} = EmployeeWorkspace.saved_views(scope, 77)
  end
end
