defmodule Bilimbi.People.WorkforceTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Snapshot

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    EmployeeFixtures.create_employee_tables!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "Tenant A"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Tenant B", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})

    CompanyFixtures.insert_company!(%{
      id: 76,
      tenant_id: 41,
      name: "Company D",
      code: "d",
      status: "suspended"
    })

    :ok = Employee.ensure_system_types()

    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    %{scope: scope, other_scope: other_scope}
  end

  test "native company identity keeps platform and workforce company axes explicit", %{
    scope: scope
  } do
    assert Workforce.source_id() == "people/native"
    assert {:ok, snapshot} = Workforce.company(scope, 73)
    assert {:ok, company} = Snapshot.require_current(snapshot)
    assert snapshot.source_id == "people/native"
    assert snapshot.status == :current
    assert %DateTime{} = snapshot.observed_at
    assert company.platform_company_id == 73
    assert company.workforce_company_id == 73
    assert company.reference.source_id == "people/native"
    assert company.reference.type == :company
    assert company.reference.stable_id == "73"
  end

  test "employee reads are scoped to the explicit company and contain no login actor", %{
    scope: scope,
    other_scope: other_scope
  } do
    assert {:ok, employee_a} =
             Employee.create_employee(scope, 73, %{
               employee_number: "E-1",
               full_name: "Employee One"
             })

    assert {:ok, employee_b} =
             Employee.create_employee(scope, 74, %{
               employee_number: "E-2",
               full_name: "Employee Two"
             })

    assert {:ok, _agent} =
             Employee.create_employee(scope, 73, %{
               employee_number: "A-1",
               full_name: "System Agent",
               employee_type: "agent"
             })

    assert {:ok, _inactive} =
             Employee.create_employee(scope, 73, %{
               employee_number: "E-3",
               full_name: "Employee Three",
               status: "inactive"
             })

    assert {:ok, listing} = Workforce.employees(scope, 73)
    assert {:ok, [value]} = Snapshot.require_current(listing)
    assert value.reference.stable_id == Integer.to_string(employee_a.id)
    assert value.company_reference.stable_id == "73"
    assert value.platform_company_id == 73
    assert value.workforce_company_id == 73
    refute Map.has_key?(value, :user_id)

    assert {:ok, one} = Workforce.employee(scope, 73, employee_a.id)
    assert {:ok, ^value} = Snapshot.require_current(one)
    assert {:error, :not_found} = Workforce.employee(scope, 73, employee_b.id)
    assert {:error, :not_found} = Workforce.employee(other_scope, 73, employee_a.id)
  end

  test "missing, cross-tenant, and suspended companies refuse all native reads", %{
    scope: scope,
    other_scope: other_scope
  } do
    for id <- [0, 75, 76, 999] do
      assert {:error, :not_found} = Workforce.company(scope, id)
      assert {:error, :not_found} = Workforce.employees(scope, id)
      assert {:error, :not_found} = Workforce.positions(scope, id)
    end

    assert {:error, :not_found} = Workforce.company(other_scope, 73)
  end

  test "supervisor references include only employees visible in the same workforce", %{
    scope: scope
  } do
    assert {:ok, agent} =
             Employee.create_employee(scope, 73, %{
               employee_number: "A-2",
               full_name: "Agent",
               employee_type: "agent"
             })

    assert {:ok, employee} =
             Employee.create_employee(scope, 73, %{
               employee_number: "E-4",
               full_name: "Employee Four",
               supervisor_id: agent.id
             })

    assert {:ok, snapshot} = Workforce.employee(scope, 73, employee.id)
    assert {:ok, value} = Snapshot.require_current(snapshot)
    assert value.supervisor_reference == nil

    assert {:ok, listing} = Workforce.employees(scope, 73)
    assert {:ok, [listed]} = Snapshot.require_current(listing)
    assert listed.supervisor_reference == nil
  end

  test "position and stale sources fail closed", %{scope: scope} do
    assert {:error, :unavailable} = Workforce.positions(scope, 73)

    stale = %Snapshot{
      source_id: "people/native",
      status: :stale,
      observed_at: ~U[2026-01-01 00:00:00Z],
      value: [:old]
    }

    assert {:error, :stale} = Snapshot.require_current(stale)
    assert {:error, :unavailable} = Snapshot.require_current(%{stale | status: :unavailable})
  end
end
