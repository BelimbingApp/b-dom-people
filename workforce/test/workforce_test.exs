defmodule Bilimbi.People.WorkforceTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Contributions
  alias Bilimbi.People.Workforce.ReadResult

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{descriptor: %{id: "people/workforce"}, payload: Contributions.contributions().settings}
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "people-workforce-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    EmployeeFixtures.create_employee_tables!()
    SettingsFixtures.create_settings_table!()

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
    assert {:ok, %ReadResult{value: company, freshness: :current}} = Workforce.company(scope, 73)
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

    assert {:ok, %ReadResult{value: [value], freshness: :current}} =
             Workforce.employees(scope, 73)

    assert value.reference.stable_id == Integer.to_string(employee_a.id)
    assert value.company_reference.stable_id == "73"
    assert value.platform_company_id == 73
    assert value.workforce_company_id == 73
    refute Map.has_key?(value, :user_id)

    assert {:ok, %ReadResult{value: ^value, freshness: :current}} =
             Workforce.employee(scope, 73, employee_a.id)

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
      assert {:error, :not_found} = Workforce.working_statuses(scope, id)
      assert {:error, :not_found} = Workforce.put_working_statuses(scope, id, ["active"])
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

    assert {:ok, %ReadResult{value: value, freshness: :current}} =
             Workforce.employee(scope, 73, employee.id)

    assert value.supervisor_reference == nil

    assert {:ok, %ReadResult{value: [listed], freshness: :current}} =
             Workforce.employees(scope, 73)

    assert listed.supervisor_reference == nil
  end

  test "probation and active employees are working staff by default; terminated are not", %{
    scope: scope
  } do
    probation = create_employee!(scope, 73, "P-1", "probation")
    active = create_employee!(scope, 73, "A-1", "active", probation.id)
    terminated = create_employee!(scope, 73, "T-1", "terminated")
    supervised = create_employee!(scope, 73, "S-1", "active", terminated.id)

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)

    assert {:ok, %ReadResult{value: listing, freshness: :current}} =
             Workforce.employees(scope, 73)

    assert Enum.map(listing, & &1.reference.stable_id) |> Enum.sort() ==
             Enum.map([probation, active, supervised], &Integer.to_string(&1.id)) |> Enum.sort()

    assert {:ok, %ReadResult{freshness: :current}} = Workforce.employee(scope, 73, probation.id)

    assert {:ok, %ReadResult{value: active_value, freshness: :current}} =
             Workforce.employee(scope, 73, active.id)

    assert active_value.supervisor_reference.stable_id == Integer.to_string(probation.id)
    assert {:error, :not_found} = Workforce.employee(scope, 73, terminated.id)

    assert {:ok, %ReadResult{value: supervised_value, freshness: :current}} =
             Workforce.employee(scope, 73, supervised.id)

    assert supervised_value.supervisor_reference == nil
  end

  test "employees_by_ids exposes only working employees of the company among bounded IDs", %{
    scope: scope,
    other_scope: other_scope
  } do
    supervisor = create_employee!(scope, 73, "S-1", "active")
    working = create_employee!(scope, 73, "E-1", "active", supervisor.id)
    leaver = create_employee!(scope, 73, "E-2", "terminated")
    sibling = create_employee!(scope, 74, "E-3", "active")

    {:ok, agent} =
      Employee.create_employee(scope, 73, %{
        employee_number: "A-1",
        full_name: "System Agent",
        employee_type: "agent"
      })

    assert {:ok, [value]} =
             Workforce.employees_by_ids(scope, 73, [working.id, leaver.id, sibling.id, agent.id])

    assert value.reference.stable_id == Integer.to_string(working.id)
    assert value.supervisor_reference.stable_id == Integer.to_string(supervisor.id)
    assert {:ok, []} = Workforce.employees_by_ids(scope, 73, [])
    assert {:error, :not_found} = Workforce.employees_by_ids(other_scope, 73, [working.id])

    assert {:error, :invalid_options} =
             Workforce.employees_by_ids(scope, 73, Enum.to_list(1..1_001))

    assert {:error, :invalid_options} = Workforce.employees_by_ids(scope, 73, ["1"])
  end

  test "working statuses are a per-company setting", %{scope: scope} do
    probation = create_employee!(scope, 73, "P-2", "probation")
    active = create_employee!(scope, 73, "A-2", "active", probation.id)
    other_probation = create_employee!(scope, 74, "P-3", "probation")

    assert {:ok, ["active"]} = Workforce.put_working_statuses(scope, 73, ["active"])

    assert {:ok, %ReadResult{value: ["active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 74)

    assert {:ok, %ReadResult{value: [only], freshness: :current}} =
             Workforce.employees(scope, 73)

    assert only.reference.stable_id == Integer.to_string(active.id)
    assert only.supervisor_reference == nil
    assert {:error, :not_found} = Workforce.employee(scope, 73, probation.id)

    assert {:ok, %ReadResult{freshness: :current}} =
             Workforce.employee(scope, 74, other_probation.id)

    assert {:ok, ["probation", "active", "terminated"]} =
             Workforce.put_working_statuses(scope, 73, ["terminated", "active", "probation"])
  end

  test "working statuses reject empty and unknown values", %{scope: scope} do
    for statuses <- [[], ["retired"], ["active", 1], "active", nil] do
      assert {:error, :invalid_statuses} = Workforce.put_working_statuses(scope, 73, statuses)
    end

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)
  end

  test "read results carry freshness and refuse stale or unavailable data" do
    last_confirmed_at = ~U[2026-09-29 12:30:00Z]
    current = ReadResult.current(:value)
    stale = ReadResult.stale(:cached_value, last_confirmed_at)
    unavailable = ReadResult.unavailable(:provider_unavailable)

    assert current.freshness == :current
    assert {:ok, :value} = ReadResult.require_current(current)

    assert stale.freshness == {:stale, last_confirmed_at}

    assert {:error, {:not_current, {:stale, ^last_confirmed_at}}} =
             ReadResult.require_current(stale)

    assert unavailable.freshness == {:unavailable, :provider_unavailable}

    assert {:error, {:not_current, {:unavailable, :provider_unavailable}}} =
             ReadResult.require_current(unavailable)
  end

  defp create_employee!(scope, company_id, number, status, supervisor_id \\ nil) do
    {:ok, employee} =
      Employee.create_employee(scope, company_id, %{
        employee_number: number,
        full_name: "Employee " <> number,
        status: status,
        supervisor_id: supervisor_id
      })

    employee
  end
end
