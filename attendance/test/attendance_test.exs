defmodule Bilimbi.People.AttendanceTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Contributions
  alias Bilimbi.People.Attendance.TestFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{descriptor: %{id: "people/attendance"}, payload: Contributions.contributions().settings}
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "attendance-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    EmployeeFixtures.create_employee_tables!()
    SettingsFixtures.create_settings_table!()
    TestFixtures.create_attendance_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    %{scope: scope, other_scope: other_scope, employee: employee}
  end

  test "records once and projects a scoped day", %{scope: scope, employee: employee} do
    first = %{
      source: "provider",
      event_key: "one",
      event_type: "in",
      occurred_at: ~U[2026-09-30 09:00:00Z]
    }

    assert {:ok, event} = Attendance.record_clock(scope, 73, employee.id, first)
    assert {:ok, ^event} = Attendance.record_clock(scope, 73, employee.id, first)

    assert {:error, :event_key_conflict} =
             Attendance.record_clock(scope, 73, employee.id, %{first | event_type: "out"})

    assert {:ok, [_]} = Attendance.list_days(scope, 73, employee.id)

    assert {:ok, _} =
             Attendance.record_clock(scope, 73, employee.id, %{
               first
               | event_key: "two",
                 event_type: "out",
                 occurred_at: ~U[2026-09-30 17:00:00Z]
             })

    assert {:ok, [%{worked_minutes: 480, status: "ready_for_review"}]} =
             Attendance.list_days(scope, 73, employee.id)
  end

  test "later events on an existing day write no failed audit capture", %{
    scope: scope,
    employee: employee
  } do
    handler = "attendance-audit-#{System.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:bilimbi, :base, :audit, :capture_failure],
      fn _, _, meta, _ -> send(test_pid, {:capture_failure, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {key, type, at} <- [
          {"in", "in", ~U[2026-09-30 09:00:00Z]},
          {"out", "out", ~U[2026-09-30 17:00:00Z]}
        ] do
      assert {:ok, _} =
               Attendance.record_clock(scope, 73, employee.id, %{
                 source: "provider",
                 event_key: key,
                 event_type: type,
                 occurred_at: at
               })
    end

    refute_received {:capture_failure, _}
    assert {:ok, [%{worked_minutes: 480}]} = Attendance.list_days(scope, 73, employee.id)
  end

  test "refuses sibling and tenant crossovers", %{
    scope: scope,
    other_scope: other,
    employee: employee
  } do
    attrs = %{
      source: "provider",
      event_key: "one",
      event_type: "in",
      occurred_at: ~U[2026-09-30 09:00:00Z]
    }

    assert {:error, :not_found} = Attendance.record_clock(scope, 74, employee.id, attrs)
    assert {:error, :not_found} = Attendance.record_clock(other, 73, employee.id, attrs)
    assert {:error, :not_found} = Attendance.list_days(scope, 74, employee.id)
  end

  test "company policy controls local date and self clocking", %{scope: scope, employee: employee} do
    assert {:ok, %{self_clock_enabled: false}} = Attendance.rules(scope, 73)

    assert {:ok, %{timezone: "Asia/Kuala_Lumpur", self_clock_enabled: true}} =
             Attendance.put_rules(scope, 73, "Asia/Kuala_Lumpur", true)

    assert {:ok, _} =
             Attendance.record_clock(scope, 73, employee.id, %{
               source: "provider",
               event_key: "local",
               event_type: "in",
               occurred_at: ~U[2026-09-30 18:00:00Z]
             })

    assert {:ok, [%{on_date: ~D[2026-10-01]}]} = Attendance.list_days(scope, 73, employee.id)
    assert {:ok, %{self_clock_enabled: false}} = Attendance.rules(scope, 74)
  end

  test "replays stay idempotent after the company time zone changes", %{
    scope: scope,
    employee: employee
  } do
    attrs = %{
      source: "provider",
      event_key: "one",
      event_type: "in",
      occurred_at: ~U[2026-09-30 09:00:00Z]
    }

    assert {:ok, event} = Attendance.record_clock(scope, 73, employee.id, attrs)
    assert {:ok, _} = Attendance.put_rules(scope, 73, "Asia/Kuala_Lumpur", false)
    assert {:ok, ^event} = Attendance.record_clock(scope, 73, employee.id, attrs)
  end

  test "an out before the first in stays pending", %{scope: scope, employee: employee} do
    out = %{
      source: "provider",
      event_key: "out",
      event_type: "out",
      occurred_at: ~U[2026-09-30 08:00:00Z]
    }

    assert {:ok, _} = Attendance.record_clock(scope, 73, employee.id, out)

    assert {:ok, _} =
             Attendance.record_clock(scope, 73, employee.id, %{
               out
               | event_key: "in",
                 event_type: "in",
                 occurred_at: ~U[2026-09-30 09:00:00Z]
             })

    assert {:ok, [%{worked_minutes: 0, status: "exception_pending"}]} =
             Attendance.list_days(scope, 73, employee.id)
  end
end
