defmodule Bilimbi.People.OrganisationTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Audit.TestFixtures, as: AuditFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.People.Organisation
  alias Bilimbi.People.Organisation.PositionAssignment
  alias Bilimbi.People.Organisation.TestFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions
  alias Bilimbi.People.Workforce.ReadResult

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        }
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "people-organisation-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    EmployeeFixtures.create_employee_tables!()
    SettingsFixtures.create_settings_table!()
    AuditFixtures.create_audit_tables!()
    TestFixtures.create_position_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    :ok = Employee.ensure_system_types()

    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    %{scope: scope, other_scope: other_scope}
  end

  test "versions and assignments have independent clocks; vacancy keeps the title", %{
    scope: scope
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-1"})

    {:ok, holder} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    assert {:ok, _} =
             Organisation.record_version(scope, 73, position.id, %{
               version: 1,
               title: "Position Alpha",
               effective_from: ~D[2026-01-01],
               effective_to: ~D[2026-06-30]
             })

    assert {:ok, _} =
             Organisation.record_version(scope, 73, position.id, %{
               version: 2,
               title: "Position Beta",
               effective_from: ~D[2026-07-01]
             })

    assert {:ok, [past]} = Organisation.positions(scope, 73, ~D[2026-03-01])
    assert past.title == "Position Alpha"
    assert past.vacant?

    assert {:ok, _} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: holder.id,
               kind: "substantive",
               effective_from: ~D[2026-04-01],
               effective_to: ~D[2026-08-31]
             })

    assert {:ok, %ReadResult{value: [occupied], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-07-15])

    assert occupied.title == "Position Beta"
    refute occupied.vacant?
    assert [%{kind: "substantive", employee_reference: reference}] = occupied.assignments
    assert reference.stable_id == Integer.to_string(holder.id)

    assert {:ok, %ReadResult{value: [vacant], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-09-01])

    assert vacant.title == "Position Beta"
    assert vacant.vacant?
  end

  test "overlapping versions and substantive holders are refused but acting cover is allowed", %{
    scope: scope
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-2"})

    {:ok, first} =
      Employee.create_employee(scope, 73, %{employee_number: "E-2", full_name: "Employee Two"})

    {:ok, second} =
      Employee.create_employee(scope, 73, %{employee_number: "E-3", full_name: "Employee Three"})

    assert {:ok, _} =
             Organisation.record_version(scope, 73, position.id, %{
               version: 1,
               title: "Title One",
               effective_from: ~D[2026-01-01],
               effective_to: ~D[2026-12-31]
             })

    assert {:error, changeset} =
             Organisation.record_version(scope, 73, position.id, %{
               version: 2,
               title: "Title Two",
               effective_from: ~D[2026-12-31]
             })

    assert changeset.errors[:effective_from]

    assert {:ok, _} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: first.id,
               kind: "substantive",
               effective_from: ~D[2026-01-01]
             })

    assert {:error, changeset} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: second.id,
               kind: "substantive",
               effective_from: ~D[2026-02-01]
             })

    assert changeset.errors[:effective_from]

    assert {:ok, _} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: second.id,
               kind: "acting",
               effective_from: ~D[2026-02-01]
             })
  end

  test "assignment refuses employees outside the working statuses and agents", %{scope: scope} do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-REFUSE"})

    {:ok, inactive} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-INACTIVE",
        full_name: "Employee Inactive",
        status: "inactive"
      })

    {:ok, agent} =
      Employee.create_employee(scope, 73, %{
        employee_number: "A-1",
        full_name: "System Agent",
        employee_type: "agent"
      })

    for employee <- [inactive, agent] do
      assert {:error, :not_found} =
               Organisation.assign(scope, 73, position.id, %{
                 employee_id: employee.id,
                 kind: "substantive",
                 effective_from: ~D[2026-01-01]
               })
    end

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)

    assert {:ok, _} = Workforce.put_working_statuses(scope, 73, ["active", "inactive"])

    assert {:ok, _} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: inactive.id,
               kind: "substantive",
               effective_from: ~D[2026-01-01]
             })
  end

  test "termination frees the seat at read time and keeps the assignment as history", %{
    scope: scope
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-FREE"})

    {:ok, holder} =
      Employee.create_employee(scope, 73, %{employee_number: "E-FREE", full_name: "Holder"})

    {:ok, cover} =
      Employee.create_employee(scope, 73, %{employee_number: "E-COVER", full_name: "Cover"})

    {:ok, assignment} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: holder.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    {:ok, _} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: cover.id,
        kind: "acting",
        effective_from: ~D[2026-01-01]
      })

    assert {:ok, %ReadResult{value: [occupied], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-09-30])

    refute occupied.vacant?
    assert length(occupied.assignments) == 2

    assert {:ok, _} = Employee.update_employee(scope, 73, holder.id, %{status: "terminated"})

    assert {:ok, %ReadResult{value: [freed], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-09-30])

    assert freed.vacant?

    assert [%{kind: "acting", employee_reference: reference}] = freed.assignments
    assert reference.stable_id == Integer.to_string(cover.id)

    assert %PositionAssignment{employee_id: employee_id, effective_to: nil} =
             Repo.get(PositionAssignment, assignment.id)

    assert employee_id == holder.id
  end

  test "a new substantive holder releases a seat held by a non-working employee", %{
    scope: scope
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-REFILL"})

    {:ok, leaver} =
      Employee.create_employee(scope, 73, %{employee_number: "E-LEAVER", full_name: "Leaver"})

    {:ok, successor} =
      Employee.create_employee(scope, 73, %{employee_number: "E-NEXT", full_name: "Successor"})

    {:ok, previous} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: leaver.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    assert {:error, changeset} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: successor.id,
               kind: "substantive",
               effective_from: ~D[2026-10-01]
             })

    assert changeset.errors[:effective_from]

    assert {:ok, _} = Employee.update_employee(scope, 73, leaver.id, %{status: "terminated"})

    assert {:ok, current} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: successor.id,
               kind: "substantive",
               effective_from: ~D[2026-10-01]
             })

    assert %PositionAssignment{effective_from: ~D[2026-01-01], effective_to: ~D[2026-09-30]} =
             Repo.get(PositionAssignment, previous.id)

    assert {:ok, %ReadResult{value: [held], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-10-15])

    refute held.vacant?
    assert [%{employee_reference: reference}] = held.assignments
    assert reference.stable_id == Integer.to_string(successor.id)
    assert current.effective_to == nil

    assert {:ok, [action]} = Audit.list_actions(scope)
    assert action.event == "people.organisation.assignment_released"
    assert action.company_id == 73
    assert action.payload["assignment_id"] == previous.id
    assert action.payload["effective_to"] == "2026-09-30"
  end

  test "position reads look up only the page's holders, not the whole workforce", %{
    scope: scope
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-BOUNDED"})

    employees =
      for number <- 1..300 do
        {:ok, employee} =
          Employee.create_employee(scope, 73, %{
            employee_number: "E-B#{number}",
            full_name: "Employee #{number}"
          })

        employee
      end

    {:ok, _} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: hd(employees).id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    test_pid = self()
    handler = "organisation-bounded-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:bilimbi, :base, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        with {:ok, %{num_rows: rows}} <- metadata.result, do: send(test_pid, {:rows, rows})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %ReadResult{value: [projected], freshness: :current}} =
             Workforce.positions(scope, 73, ~D[2026-09-30])

    :telemetry.detach(handler)
    refute projected.vacant?

    counts = collect_rows([])
    assert counts != []
    assert Enum.max(counts) < 10
  end

  test "scope, company and cycles are refused", %{scope: scope, other_scope: other_scope} do
    {:ok, root} = Organisation.create_position(scope, 73, %{code: "ROOT"})
    {:ok, child} = Organisation.create_position(scope, 73, %{code: "CHILD", parent_id: root.id})
    {:ok, foreign} = Organisation.create_position(scope, 74, %{code: "FOREIGN"})

    {:ok, employee} =
      Employee.create_employee(scope, 74, %{employee_number: "E-4", full_name: "Employee Four"})

    assert {:error, :cycle} = Organisation.set_parent(scope, 73, root.id, child.id)
    assert {:error, :not_found} = Organisation.set_parent(scope, 73, root.id, foreign.id)
    assert {:error, :not_found} = Organisation.positions(other_scope, 73)
    assert {:error, :not_found} = Organisation.positions(scope, 75)

    assert {:error, :not_found} =
             Organisation.assign(scope, 73, root.id, %{
               employee_id: employee.id,
               kind: "acting",
               effective_from: ~D[2026-01-01]
             })

    assert {:error, :not_found} =
             Organisation.record_version(scope, 73, foreign.id, %{
               version: 1,
               title: "Wrong",
               effective_from: ~D[2026-01-01]
             })
  end

  test "the explorer page is bounded", %{scope: scope} do
    for number <- 1..3 do
      {:ok, _} = Organisation.create_position(scope, 73, %{code: "P-#{number}"})
    end

    assert {:ok, first} =
             Organisation.positions(scope, 73, Date.utc_today(), page: 1, page_size: 2)

    assert length(first) == 2

    assert {:ok, second} =
             Organisation.positions(scope, 73, Date.utc_today(), page: 2, page_size: 2)

    assert length(second) == 1

    assert {:error, :invalid_options} =
             Organisation.positions(scope, 73, Date.utc_today(), page_size: 101)
  end

  test "workforce position reads report unavailable when Organisation is absent", %{scope: scope} do
    :ok = Workforce.unregister_position_reader(Organisation)
    on_exit(fn -> Workforce.register_position_reader(Organisation) end)

    assert {:error, :unavailable} = Workforce.positions(scope, 73)
    assert {:error, :not_found} = Workforce.positions(scope, 75)
  end

  test "many acting placements stay bounded without hiding a substantive holder", %{scope: scope} do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-LARGE"})

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-LARGE",
        full_name: "Employee Large"
      })

    for _ <- 1..501 do
      assert {:ok, _} =
               Organisation.assign(scope, 73, position.id, %{
                 employee_id: employee.id,
                 kind: "acting",
                 effective_from: ~D[2026-01-01]
               })
    end

    assert {:ok, _} =
             Organisation.assign(scope, 73, position.id, %{
               employee_id: employee.id,
               kind: "substantive",
               effective_from: ~D[2026-01-01]
             })

    assert {:ok, [projected]} = Organisation.positions(scope, 73, ~D[2026-09-30])
    assert length(projected.assignments) == 500
    assert projected.assignments_incomplete?
    refute projected.vacant?
  end

  defp collect_rows(counts) do
    receive do
      {:rows, rows} -> collect_rows([rows | counts])
    after
      0 -> counts
    end
  end
end
