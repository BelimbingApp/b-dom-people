defmodule Bilimbi.People.Attendance.RostersTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Bilimbi.Base.Audit.TestFixtures, as: AuditFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.{ClockEvent, Contributions, TestFixtures}
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @employee_actor %{type: :user, company_id: 73, id: 91}
  @approver_actor %{type: :user, company_id: 73, id: 92}

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
      graph_fingerprint: "attendance-rosters-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    AuditFixtures.create_audit_tables!()
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

    {:ok, approver} =
      Employee.create_employee(scope, 73, %{employee_number: "E-2", full_name: "Approver Two"})

    UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})

    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      employee_id: approver.id,
      email: "approver@example.com"
    })

    %{scope: scope, other_scope: other_scope, employee: employee, approver: approver}
  end

  defp shift!(scope, code \\ "day", starts \\ "09:00", ends \\ "17:00") do
    {:ok, template} =
      Attendance.create_shift_template(scope, 73, %{
        "code" => code,
        "name" => "Shift #{code}",
        "starts_at" => starts,
        "ends_at" => ends,
        "break_minutes" => "30"
      })

    template
  end

  describe "shift templates" do
    test "validate span, codes and company scope", %{scope: scope, other_scope: other} do
      night = shift!(scope, "night", "22:00", "06:00")
      assert night.start_minute == 22 * 60 and night.end_minute == 6 * 60
      assert Attendance.ShiftTemplate.span_minutes(night) == 480

      assert {:error, %Ecto.Changeset{errors: [company_id: _]}} =
               Attendance.create_shift_template(scope, 73, %{
                 "code" => "night",
                 "name" => "Again",
                 "starts_at" => "08:00",
                 "ends_at" => "10:00"
               })

      assert {:error, %Ecto.Changeset{} = same} =
               Attendance.create_shift_template(scope, 73, %{
                 "code" => "same",
                 "name" => "Same",
                 "starts_at" => "08:00",
                 "ends_at" => "08:00"
               })

      assert Keyword.has_key?(same.errors, :ends_at)

      assert {:error, %Ecto.Changeset{} = long_break} =
               Attendance.create_shift_template(scope, 73, %{
                 "code" => "short",
                 "name" => "Short",
                 "starts_at" => "08:00",
                 "ends_at" => "09:00",
                 "break_minutes" => "60"
               })

      assert Keyword.has_key?(long_break.errors, :break_minutes)

      assert {:error, %Ecto.Changeset{} = blank_break} =
               Attendance.create_shift_template(scope, 73, %{
                 "code" => "blank",
                 "name" => "Blank",
                 "starts_at" => "08:00",
                 "ends_at" => "17:00",
                 "break_minutes" => ""
               })

      assert Keyword.has_key?(blank_break.errors, :break_minutes)
      assert {:ok, []} = Attendance.list_shift_templates(scope, 74)
      assert {:error, :not_found} = Attendance.list_shift_templates(other, 73)

      assert {:error, :not_found} =
               Attendance.set_shift_template_status(scope, 74, night.id, "retired")
    end
  end

  describe "roster" do
    test "drafts stay hidden from the employee until published", %{
      scope: scope,
      employee: employee
    } do
      day = shift!(scope)
      date = Date.utc_today()

      assert {:ok, %{kind: "shift", pending?: true}} =
               Attendance.plan_roster_entry(
                 scope,
                 73,
                 @approver_actor,
                 employee.id,
                 date,
                 {:shift, day.id}
               )

      assert {:ok, []} = Attendance.self_roster(scope, 73, @employee_actor, date, 7)
      assert {:ok, %{pending: 1}} = Attendance.roster(scope, 73, date, 7)

      assert {:ok, %{employees: [], pending: 1}} =
               Attendance.roster(scope, 73, date, 7, query: "no such employee")

      assert {:ok, 1} =
               Attendance.publish_roster(scope, 73, @approver_actor, date, Date.add(date, 6))

      assert {:ok, [%{kind: "shift", shift_code: "day", start_minute: 540}]} =
               Attendance.self_roster(scope, 73, @employee_actor, date, 7)

      # A published entry keeps showing its published value while a change is pending.
      assert {:ok, %{kind: "rest", pending?: true}} =
               Attendance.plan_roster_entry(scope, 73, @approver_actor, employee.id, date, :rest)

      assert {:ok, [%{kind: "shift"}]} =
               Attendance.self_roster(scope, 73, @employee_actor, date, 7)

      assert {:ok, 1} = Attendance.publish_roster(scope, 73, @approver_actor, date, date)

      assert {:ok, [%{kind: "rest"}]} =
               Attendance.self_roster(scope, 73, @employee_actor, date, 7)

      assert {:ok, %{kind: "none"}} =
               Attendance.plan_roster_entry(scope, 73, @approver_actor, employee.id, date, :none)

      assert {:ok, 1} = Attendance.publish_roster(scope, 73, @approver_actor, date, date)
      assert {:ok, []} = Attendance.self_roster(scope, 73, @employee_actor, date, 7)
      assert {:ok, %{entries: entries, pending: 0}} = Attendance.roster(scope, 73, date, 7)
      assert entries == %{}
    end

    test "clearing an unpublished draft removes it", %{scope: scope, employee: employee} do
      date = Date.utc_today()

      assert {:ok, _} =
               Attendance.plan_roster_entry(scope, 73, @approver_actor, employee.id, date, :rest)

      assert {:ok, nil} =
               Attendance.plan_roster_entry(scope, 73, @approver_actor, employee.id, date, :none)

      assert {:ok, %{entries: entries}} = Attendance.roster(scope, 73, date, 1)
      assert entries == %{}
    end

    test "refuses retired shifts, foreign employees and unbounded periods", %{
      scope: scope,
      other_scope: other,
      employee: employee
    } do
      day = shift!(scope)
      assert {:ok, _} = Attendance.set_shift_template_status(scope, 73, day.id, "retired")
      date = Date.utc_today()

      assert {:error, :shift_unavailable} =
               Attendance.plan_roster_entry(
                 scope,
                 73,
                 @approver_actor,
                 employee.id,
                 date,
                 {:shift, day.id}
               )

      assert {:error, :not_found} =
               Attendance.plan_roster_entry(scope, 74, @approver_actor, employee.id, date, :rest)

      assert {:error, :not_found} =
               Attendance.plan_roster_entry(other, 73, @approver_actor, employee.id, date, :rest)

      assert {:error, :invalid_period} = Attendance.roster(scope, 73, date, 32)

      assert {:error, :invalid_period} =
               Attendance.publish_roster(scope, 73, @approver_actor, date, Date.add(date, 31))
    end

    test "publishing records an audit action", %{scope: scope, employee: employee} do
      date = Date.utc_today()

      assert {:ok, _} =
               Attendance.plan_roster_entry(scope, 73, @approver_actor, employee.id, date, :rest)

      assert {:ok, 1} = Attendance.publish_roster(scope, 73, @approver_actor, date, date)

      assert [%{"entries" => 1}] =
               Repo.all(
                 from(a in "base_audit_actions",
                   where: a.event == "people.attendance.roster_published",
                   select: a.payload
                 )
               )
    end

    test "search narrows the employees shown", %{scope: scope} do
      assert {:ok, %{employees: [%{name: "Approver Two"}]}} =
               Attendance.roster(scope, 73, Date.utc_today(), 7, query: "approver")
    end
  end

  describe "clocking locations" do
    setup %{scope: scope} do
      {:ok, site} =
        Attendance.create_clocking_location(scope, 73, %{
          "code" => "site",
          "name" => "Site",
          "latitude" => "3.139000",
          "longitude" => "101.686900",
          "radius_meters" => "200"
        })

      %{site: site}
    end

    test "a required location refuses events without or outside it", %{
      scope: scope,
      employee: employee,
      site: site
    } do
      assert {:ok, _} = Attendance.put_rules(scope, 73, %{location_required: true})

      event = %{
        source: "device",
        event_key: "one",
        event_type: "in",
        occurred_at: ~U[2026-09-30 01:00:00Z]
      }

      assert {:error, :location_required} = Attendance.record_clock(scope, 73, employee.id, event)

      assert {:error, :outside_clocking_location} =
               Attendance.record_clock(
                 scope,
                 73,
                 employee.id,
                 Map.merge(event, %{latitude: 3.15, longitude: 101.6869})
               )

      assert {:ok, %{id: id}} =
               Attendance.record_clock(
                 scope,
                 73,
                 employee.id,
                 Map.merge(event, %{latitude: 3.1395, longitude: 101.687})
               )

      assert %ClockEvent{clocking_location_id: location_id} = Repo.get!(ClockEvent, id)
      assert location_id == site.id

      assert {:ok, _} = Attendance.set_clocking_location_status(scope, 73, site.id, "retired")

      assert {:error, :outside_clocking_location} =
               Attendance.record_clock(
                 scope,
                 73,
                 employee.id,
                 Map.merge(event, %{event_key: "two", latitude: 3.1395, longitude: 101.687})
               )
    end

    test "self clocking refuses a caller-supplied actor on a system scope", %{scope: scope} do
      assert {:ok, _} =
               Attendance.put_rules(scope, 73, %{
                 self_clock_enabled: true,
                 location_required: true
               })

      assert {:error, :unavailable} =
               Attendance.self_clock(scope, 73, @employee_actor, "in", "key")
    end

    test "locations are validated and company scoped", %{scope: scope, other_scope: other} do
      assert {:error, %Ecto.Changeset{}} =
               Attendance.create_clocking_location(scope, 73, %{
                 "code" => "bad",
                 "name" => "Bad",
                 "latitude" => "91",
                 "longitude" => "0",
                 "radius_meters" => "10"
               })

      assert {:ok, []} = Attendance.list_clocking_locations(scope, 74)
      assert {:error, :not_found} = Attendance.list_clocking_locations(other, 73)
    end
  end

  describe "adjustments" do
    defp local_now_minus(seconds) do
      DateTime.utc_now()
      |> DateTime.add(-seconds)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
    end

    defp submit(scope, key, local_at, type \\ "in") do
      Attendance.submit_adjustment(scope, 73, @employee_actor, %{
        "request_key" => key,
        "event_type" => type,
        "local_at" => local_at,
        "reason" => "Forgot to clock"
      })
    end

    test "approval writes the clock event and projects the day", %{
      scope: scope,
      employee: employee
    } do
      at = local_now_minus(3600)
      assert {:ok, request} = submit(scope, "k1", at)
      assert request.status == "pending"
      assert {:ok, ^request} = submit(scope, "k1", at)
      assert {:error, :request_key_conflict} = submit(scope, "k1", at, "out")
      assert {:error, :duplicate_request} = submit(scope, "k2", at)

      assert {:ok, [%{employee_name: "Employee One (E-1)"}]} =
               Attendance.pending_adjustments(scope, 73)

      assert {:ok, approved} =
               Attendance.decide_adjustment(scope, 73, @approver_actor, request.id, :approve, nil)

      assert approved.status == "approved" and approved.decided_by_user_id == 92

      assert %ClockEvent{source: "adjustment", actor_user_id: 92, event_type: "in"} =
               Repo.get!(ClockEvent, approved.applied_clock_event_id)

      assert {:ok, [%{status: "in_progress"}]} = Attendance.list_days(scope, 73, employee.id)

      assert {:error, :not_pending} =
               Attendance.decide_adjustment(scope, 73, @approver_actor, request.id, :reject, "no")

      assert {:ok, []} = Attendance.pending_adjustments(scope, 73)

      assert [_] =
               Repo.all(
                 from(a in "base_audit_actions",
                   where: a.event == "people.attendance.adjustment_approved",
                   select: a.id
                 )
               )
    end

    test "approval is exempt from the location requirement", %{scope: scope} do
      assert {:ok, _} = Attendance.put_rules(scope, 73, %{location_required: true})
      assert {:ok, request} = submit(scope, "k1", local_now_minus(600))

      assert {:ok, %{status: "approved"}} =
               Attendance.decide_adjustment(scope, 73, @approver_actor, request.id, :approve, nil)
    end

    test "the requester and the employee cannot decide", %{scope: scope, employee: employee} do
      assert {:ok, request} = submit(scope, "k1", local_now_minus(600))

      assert {:error, :self_approval} =
               Attendance.decide_adjustment(scope, 73, @employee_actor, request.id, :approve, nil)

      # Another account linked to the same employee is still the employee.
      UserFixtures.insert_user!(%{
        id: 93,
        company_id: 73,
        employee_id: employee.id,
        email: "second-login@example.com"
      })

      assert {:error, :self_approval} =
               Attendance.decide_adjustment(
                 scope,
                 73,
                 %{type: :user, company_id: 73, id: 93},
                 request.id,
                 :approve,
                 nil
               )
    end

    test "rejection needs a note and cancelled requests are final", %{scope: scope} do
      assert {:ok, first} = submit(scope, "k1", local_now_minus(600))

      assert {:error, :note_required} =
               Attendance.decide_adjustment(scope, 73, @approver_actor, first.id, :reject, " ")

      assert {:ok, %{status: "rejected", decision_note: "Not on roster"}} =
               Attendance.decide_adjustment(
                 scope,
                 73,
                 @approver_actor,
                 first.id,
                 :reject,
                 "Not on roster"
               )

      assert {:ok, second} = submit(scope, "k2", local_now_minus(900), "out")

      assert {:ok, %{status: "cancelled"}} =
               Attendance.cancel_adjustment(scope, 73, @employee_actor, second.id)

      assert {:error, :not_pending} =
               Attendance.cancel_adjustment(scope, 73, @employee_actor, second.id)

      assert {:error, :not_pending} =
               Attendance.decide_adjustment(scope, 73, @approver_actor, second.id, :approve, nil)

      assert {:ok, [_, _]} = Attendance.self_adjustments(scope, 73, @employee_actor)
    end

    test "the request window and future times are refused", %{scope: scope} do
      assert {:ok, _} = Attendance.put_rules(scope, 73, %{adjustment_window_days: 2})
      assert {:error, :future_time} = submit(scope, "k1", local_now_minus(-3600))
      assert {:error, :outside_window} = submit(scope, "k2", local_now_minus(3 * 86_400))
      assert {:error, :invalid_time} = submit(scope, "k3", "not a time")
    end

    test "the local time uses the company time zone", %{scope: scope} do
      assert {:ok, _} = Attendance.put_rules(scope, 73, %{timezone: "Asia/Kuala_Lumpur"})
      local = local_now_minus(-8 * 3600 + 3600)
      assert {:ok, request} = submit(scope, "k1", local)

      assert DateTime.to_naive(request.proposed_at) == NaiveDateTime.add(local, -8 * 3600)
    end

    test "unlinked accounts and other tenants are refused", %{scope: scope, other_scope: other} do
      UserFixtures.insert_user!(%{id: 94, company_id: 73, email: "unlinked@example.com"})

      assert {:error, :unavailable} =
               Attendance.submit_adjustment(scope, 73, %{type: :user, company_id: 73, id: 94}, %{
                 "request_key" => "x",
                 "event_type" => "in",
                 "local_at" => local_now_minus(60),
                 "reason" => "r"
               })

      assert {:ok, request} = submit(scope, "k1", local_now_minus(600))

      assert {:error, :not_found} =
               Attendance.decide_adjustment(other, 73, @approver_actor, request.id, :approve, nil)

      assert {:error, :not_found} =
               Attendance.decide_adjustment(scope, 74, @approver_actor, request.id, :approve, nil)
    end
  end
end
