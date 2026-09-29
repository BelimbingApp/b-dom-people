defmodule Bilimbi.People.EmployeeWorkspaceTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.People.EmployeeWorkspace
  alias Bilimbi.People.EmployeeWorkspace.TestFixtures, as: WorkspaceFixtures

  setup do
    EmployeeFixtures.create_employee_tables!()
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
        employee_number: "EMP-01", full_name: "First Employee",
        employee_type: "full_time", status: "active"
      })

    %{first: first, second: second, employee: employee}
  end

  test "keeps Core Employee master separate and refuses other company axes", %{
    first: first, second: second, employee: employee
  } do
    assert {:ok, [%{id: id}]} = EmployeeWorkspace.employees(first, 73)
    assert id == employee.id
    assert {:error, :not_found} = EmployeeWorkspace.work_profile(first, 74, employee.id)
    assert {:error, :not_found} = EmployeeWorkspace.work_profile(second, 73, employee.id)
    assert {:error, :not_found} =
      EmployeeWorkspace.put_work_profile(first, 74, employee.id, %{work_location: "Other"})

    assert {:ok, profile} =
      EmployeeWorkspace.put_work_profile(first, 73, employee.id, %{
        work_location: "Office", work_arrangement: "Flexible"
      })

    assert profile.work_location == "Office"
    assert {:ok, %{work_location: "Office"}} =
      EmployeeWorkspace.work_profile(first, 73, employee.id)

    assert {:ok, core} = Employee.get_employee(first, 73, employee.id)
    assert core.full_name == "First Employee"
    assert {:ok, []} = EmployeeWorkspace.employees(first, 74)
  end

  test "access is only an eligibility fact and change review is one-time", %{
    first: scope, employee: employee
  } do
    assert {:ok, nil} = EmployeeWorkspace.access(scope, 73, employee.id)
    assert {:ok, %{portal_enabled: true}} =
      EmployeeWorkspace.put_access(scope, 73, employee.id, %{
        portal_enabled: true, reason: "Operator decision"
      })

    assert {:ok, request} =
      EmployeeWorkspace.request_change(scope, 73, employee.id, 91, %{
        field: "full_name", proposed_value: "Updated Name", reason: "Correction"
      })

    assert request.status == "pending"
    assert {:ok, reviewed} =
      EmployeeWorkspace.review_change(scope, 73, employee.id, request.id, 92, "approved")

    assert reviewed.status == "approved"
    assert reviewed.reviewed_by_actor_id == 92
    assert {:error, :already_reviewed} =
      EmployeeWorkspace.review_change(scope, 73, employee.id, request.id, 93, "rejected")

    assert {:ok, core} = Employee.get_employee(scope, 73, employee.id)
    assert core.full_name == "First Employee"
  end

  test "saved views are private to actor and company", %{first: scope} do
    assert {:ok, view} =
      EmployeeWorkspace.save_view(scope, 73, 91, %{
        name: "Current", search: "first", status: "active"
      })

    assert {:ok, [%{name: "Current"}]} = EmployeeWorkspace.saved_views(scope, 73, 91)
    assert {:ok, []} = EmployeeWorkspace.saved_views(scope, 73, 92)
    assert {:ok, []} = EmployeeWorkspace.saved_views(scope, 74, 91)
    assert {:error, :not_found} = EmployeeWorkspace.delete_view(scope, 73, 92, view.id)
    assert {:ok, :deleted} = EmployeeWorkspace.delete_view(scope, 73, 91, view.id)
    assert {:ok, []} = EmployeeWorkspace.saved_views(scope, 73, 91)
  end
end
