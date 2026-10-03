defmodule Bilimbi.People.OrganisationTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Audit.TestFixtures, as: AuditFixtures
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Organisation
  alias Bilimbi.People.Organisation.Contributions
  alias Bilimbi.People.Organisation.PositionAssignment
  alias Bilimbi.People.Organisation.TestFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions
  alias Bilimbi.People.Workforce.ReadResult

  @manage "people.organisation.manage"
  @workforce_settings "people.workforce.settings.manage"

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

    AuthorizationFixtures.install_snapshot!("people-organisation-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions, WorkforceContributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    AuditFixtures.create_audit_tables!()
    TestFixtures.create_position_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    :ok = Employee.ensure_system_types()

    {:ok, system} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    # Writes are performed by a signed-in manager; the system scope stays for
    # Core fixture setup and public reads.
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Manager"})
    scope = AuthorizationFixtures.sign_in!(system, 73, 91, [@manage, @workforce_settings])

    %{scope: scope, system: system, other_scope: other_scope}
  end

  test "writes need the manage capability now, for the actor's own company", %{
    scope: scope,
    system: system
  } do
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-AUTH"})

    {:ok, holder} =
      Employee.create_employee(system, 73, %{employee_number: "E-AUTH", full_name: "Holder"})

    version = %{version: 1, title: "Title", effective_from: ~D[2026-01-01]}
    placement = %{employee_id: holder.id, kind: "substantive", effective_from: ~D[2026-01-01]}

    # A system scope names nobody.
    assert {:error, :unauthorized} = Organisation.create_position(system, 73, %{code: "P-SYS"})
    assert {:error, :unauthorized} = Organisation.record_version(system, 73, position.id, version)
    assert {:error, :unauthorized} = Organisation.assign(system, 73, position.id, placement)
    assert {:error, :unauthorized} = Organisation.set_parent(system, 73, position.id, nil)

    # The grant is per company: a sibling company is out of reach.
    assert {:error, :unauthorized} = Organisation.create_position(scope, 74, %{code: "P-SIB"})

    {:ok, assignment} = Organisation.assign(scope, 73, position.id, placement)

    # A grant revoked after sign-in is refused on the next write.
    :ok = AuthorizationFixtures.revoke!(system, 73, 91, @manage)

    assert {:error, :unauthorized} =
             Organisation.end_assignment(scope, 73, assignment.id, ~D[2026-09-30])

    assert {:error, :unauthorized} = Organisation.record_version(scope, 73, position.id, version)
    assert %PositionAssignment{effective_to: nil} = Repo.get(PositionAssignment, assignment.id)

    # Reads stay open to the tenant scope.
    assert {:ok, [_position]} = Organisation.positions(system, 73, ~D[2026-06-01])
    assert {:ok, 1} = Organisation.count_positions(system, 73)
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

  test "scope, company and cycles are refused", %{
    scope: scope,
    system: system,
    other_scope: other_scope
  } do
    {:ok, root} = Organisation.create_position(scope, 73, %{code: "ROOT"})
    {:ok, child} = Organisation.create_position(scope, 73, %{code: "CHILD", parent_id: root.id})

    # The sibling company's position is seeded by a manager signed in there.
    UserFixtures.insert_user!(%{id: 93, company_id: 74, name: "Other", email: "o@example.com"})
    sibling = AuthorizationFixtures.sign_in!(system, 74, 93, [@manage])
    {:ok, foreign} = Organisation.create_position(sibling, 74, %{code: "FOREIGN"})

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

  test "cursor iteration survives inserts and deletes between pages", %{scope: scope} do
    positions =
      for number <- 1..5 do
        {:ok, position} = Organisation.create_position(scope, 73, %{code: "PAGE-#{number}"})
        position
      end

    {:ok, foreign} = Organisation.create_position(scope, 74, %{code: "PAGE-OTHER"})
    day = ~D[2026-10-01]
    high_water_id = foreign.id

    assert {:ok, %ReadResult{freshness: :current, value: first}} =
             Workforce.positions(scope, 73, day, cursor: nil, page_size: 2)

    assert Enum.map(first.positions, & &1.reference.stable_id) ==
             Enum.map(Enum.take(positions, 2), &Integer.to_string(&1.id))

    refute Integer.to_string(foreign.id) in Enum.map(first.positions, & &1.reference.stable_id)
    assert first.high_water_id == high_water_id
    assert is_binary(first.next_cursor)

    supervisor = start_supervised!(Task.Supervisor)

    inserted =
      supervisor
      |> Task.Supervisor.async(fn ->
        Repo.delete!(hd(positions))
        Repo.delete!(Enum.at(positions, 3))
        {:ok, inserted} = Organisation.create_position(scope, 73, %{code: "PAGE-NEW"})
        inserted
      end)
      |> Task.await()

    assert {:ok, %ReadResult{value: second}} =
             Workforce.positions(scope, 73, day, cursor: first.next_cursor, page_size: 1)

    assert {:ok, %ReadResult{value: third}} =
             Workforce.positions(scope, 73, day, cursor: second.next_cursor, page_size: 1)

    assert second.high_water_id == high_water_id
    assert third.high_water_id == high_water_id
    assert third.next_cursor == nil

    seen =
      Enum.map(first.positions ++ second.positions ++ third.positions, & &1.reference.stable_id)

    assert seen ==
             Enum.map(
               Enum.take(positions, 3) ++ [List.last(positions)],
               &Integer.to_string(&1.id)
             )

    refute Integer.to_string(inserted.id) in seen

    # Absence reconciliation must preserve new identities above the returned watermark.
    absent = Enum.reject(positions ++ [inserted], &(Integer.to_string(&1.id) in seen))

    assert Enum.map(Enum.filter(absent, &(&1.id <= high_water_id)), & &1.id) ==
             [Enum.at(positions, 3).id]

    assert {:ok, %ReadResult{value: fresh}} =
             Workforce.positions(scope, 73, day, cursor: nil, page_size: 100)

    assert fresh.high_water_id == inserted.id
    assert fresh.next_cursor == nil
    assert Integer.to_string(inserted.id) in Enum.map(fresh.positions, & &1.reference.stable_id)
  end

  test "cursor pages bind the company, tenant and date and reject invalid options", %{
    scope: scope,
    other_scope: other_scope
  } do
    for number <- 1..2 do
      {:ok, _} = Organisation.create_position(scope, 73, %{code: "CURSOR-#{number}"})
    end

    day = ~D[2026-10-01]

    assert {:ok, %ReadResult{value: page}} =
             Workforce.positions(scope, 73, day, cursor: nil, page_size: 1)

    assert {:error, :invalid_cursor} =
             Workforce.positions(scope, 74, day, cursor: page.next_cursor)

    assert {:error, :invalid_cursor} =
             Workforce.positions(scope, 73, Date.add(day, 1), cursor: page.next_cursor)

    assert {:error, :not_found} =
             Workforce.positions(other_scope, 73, day, cursor: page.next_cursor)

    assert {:error, :not_found} =
             Workforce.positions(scope, 75, day, cursor: nil)

    for cursor <- [
          "not-a-cursor",
          "",
          1,
          String.duplicate("x", 257),
          Base.url_encode64("1:41:73:2026-10-01:5:4", padding: false)
        ] do
      assert {:error, :invalid_cursor} = Workforce.positions(scope, 73, day, cursor: cursor)
    end

    for options <- [
          [cursor: nil, page: 1],
          [cursor: nil, page_size: 0],
          [cursor: nil, page_size: 101],
          [cursor: nil, page_size: "2"],
          [nil],
          %{}
        ] do
      assert {:error, :invalid_options} = Workforce.positions(scope, 73, day, options)
    end
  end

  test "cursor pages enforce the default and maximum size", %{scope: scope} do
    for number <- 1..105 do
      {:ok, _} = Organisation.create_position(scope, 73, %{code: "BOUND-#{number}"})
    end

    day = ~D[2026-10-01]

    assert {:ok, %ReadResult{value: default}} =
             Workforce.positions(scope, 73, day, cursor: nil)

    assert length(default.positions) == 50
    assert is_binary(default.next_cursor)

    assert {:ok, %ReadResult{value: maximum}} =
             Workforce.positions(scope, 73, day, cursor: nil, page_size: 100)

    assert length(maximum.positions) == 100

    assert {:ok, %ReadResult{value: tail}} =
             Workforce.positions(scope, 73, day, cursor: maximum.next_cursor, page_size: 100)

    assert length(tail.positions) == 5
    assert tail.next_cursor == nil
    assert tail.high_water_id == maximum.high_water_id
  end

  test "empty and deleted final cursor pages retain their high-water mark", %{scope: scope} do
    day = ~D[2026-10-01]

    assert {:ok, %ReadResult{value: %{positions: [], next_cursor: nil, high_water_id: empty}}} =
             Workforce.positions(scope, 73, day, cursor: nil)

    assert is_integer(empty) and empty >= 0

    {:ok, _first} = Organisation.create_position(scope, 73, %{code: "TAIL-1"})
    {:ok, last} = Organisation.create_position(scope, 73, %{code: "TAIL-2"})

    assert {:ok, %ReadResult{value: page}} =
             Workforce.positions(scope, 73, day, cursor: nil, page_size: 1)

    Repo.delete!(last)

    assert {:ok, %ReadResult{value: %{positions: [], next_cursor: nil, high_water_id: high}}} =
             Workforce.positions(scope, 73, day, cursor: page.next_cursor)

    assert high == last.id
  end

  test "deleting the highest position keeps it absent at or below the mark", %{scope: scope} do
    day = ~D[2026-10-01]
    {:ok, first} = Organisation.create_position(scope, 73, %{code: "TOP-1"})
    {:ok, top} = Organisation.create_position(scope, 73, %{code: "TOP-2"})

    assert {:ok, %ReadResult{value: before}} =
             Workforce.positions(scope, 73, day, cursor: nil)

    assert before.high_water_id == top.id

    Repo.delete!(top)

    assert {:ok, %ReadResult{value: after_delete}} =
             Workforce.positions(scope, 73, day, cursor: nil)

    assert after_delete.next_cursor == nil
    assert after_delete.high_water_id == top.id

    assert Enum.map(after_delete.positions, & &1.reference.stable_id) == [
             Integer.to_string(first.id)
           ]
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
