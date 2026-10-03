defmodule Bilimbi.People.Attendance.RostersTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.{ClockEvent, Contributions, TestFixtures}
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @self_capability "people.attendance.self.view"
  @approve_capability "people.attendance.adjustments.approve"
  @operator_capabilities ~w(people.attendance.rules.manage people.attendance.roster.manage
                            people.attendance.adjustments.approve)

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

    AuthorizationFixtures.install_snapshot!("attendance-rosters-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
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

    # The employee also holds the approve grant so independence, not the
    # grant, is what refuses a self decision.
    member =
      AuthorizationFixtures.sign_in!(scope, 73, 91, [@self_capability, @approve_capability])

    operator = AuthorizationFixtures.sign_in!(scope, 73, 92, @operator_capabilities)

    %{
      scope: scope,
      other_scope: other_scope,
      employee: employee,
      approver: approver,
      member: member,
      operator: operator
    }
  end

  defp shift!(operator, code \\ "day", starts \\ "09:00", ends \\ "17:00") do
    {:ok, template} =
      Attendance.create_shift_template(operator, 73, %{
        "code" => code,
        "name" => "Shift #{code}",
        "starts_at" => starts,
        "ends_at" => ends,
        "break_minutes" => "30"
      })

    template
  end

  describe "shift templates" do
    test "validate span, codes and company scope", %{
      scope: scope,
      other_scope: other,
      operator: operator
    } do
      night = shift!(operator, "night", "22:00", "06:00")
      assert night.start_minute == 22 * 60 and night.end_minute == 6 * 60
      assert Attendance.ShiftTemplate.span_minutes(night) == 480

      assert {:error, %Ecto.Changeset{errors: [company_id: _]}} =
               Attendance.create_shift_template(operator, 73, %{
                 "code" => "night",
                 "name" => "Again",
                 "starts_at" => "08:00",
                 "ends_at" => "10:00"
               })

      assert {:error, %Ecto.Changeset{} = same} =
               Attendance.create_shift_template(operator, 73, %{
                 "code" => "same",
                 "name" => "Same",
                 "starts_at" => "08:00",
                 "ends_at" => "08:00"
               })

      assert Keyword.has_key?(same.errors, :ends_at)

      assert {:error, %Ecto.Changeset{} = long_break} =
               Attendance.create_shift_template(operator, 73, %{
                 "code" => "short",
                 "name" => "Short",
                 "starts_at" => "08:00",
                 "ends_at" => "09:00",
                 "break_minutes" => "60"
               })

      assert Keyword.has_key?(long_break.errors, :break_minutes)

      assert {:error, %Ecto.Changeset{} = blank_break} =
               Attendance.create_shift_template(operator, 73, %{
                 "code" => "blank",
                 "name" => "Blank",
                 "starts_at" => "08:00",
                 "ends_at" => "17:00",
                 "break_minutes" => ""
               })

      assert Keyword.has_key?(blank_break.errors, :break_minutes)
      assert {:ok, []} = Attendance.list_shift_templates(scope, 74)
      assert {:error, :not_found} = Attendance.list_shift_templates(other, 73)

      assert {:error, :unauthorized} =
               Attendance.set_shift_template_status(operator, 74, night.id, "retired")

      assert {:error, :unauthorized} =
               Attendance.create_shift_template(scope, 73, %{"code" => "x", "name" => "X"})
    end
  end

  describe "roster" do
    test "drafts stay hidden from the employee until published", %{
      employee: employee,
      operator: operator,
      member: member
    } do
      day = shift!(operator)
      date = Date.utc_today()

      assert {:ok, %{kind: "shift", pending?: true}} =
               Attendance.plan_roster_entry(
                 operator,
                 73,
                 employee.id,
                 date,
                 {:shift, day.id}
               )

      assert {:ok, []} = Attendance.self_roster(member, 73, date, 7)
      assert {:ok, %{pending: 1}} = Attendance.roster(operator, 73, date, 7)

      assert {:ok, %{employees: [], pending: 1}} =
               Attendance.roster(operator, 73, date, 7, query: "no such employee")

      assert {:ok, 1} =
               Attendance.publish_roster(operator, 73, date, Date.add(date, 6))

      assert {:ok, [%{kind: "shift", shift_code: "day", start_minute: 540}]} =
               Attendance.self_roster(member, 73, date, 7)

      # A published entry keeps showing its published value while a change is pending.
      assert {:ok, %{kind: "rest", pending?: true}} =
               Attendance.plan_roster_entry(operator, 73, employee.id, date, :rest)

      assert {:ok, [%{kind: "shift"}]} =
               Attendance.self_roster(member, 73, date, 7)

      assert {:ok, 1} = Attendance.publish_roster(operator, 73, date, date)

      assert {:ok, [%{kind: "rest"}]} =
               Attendance.self_roster(member, 73, date, 7)

      assert {:ok, %{kind: "none"}} =
               Attendance.plan_roster_entry(operator, 73, employee.id, date, :none)

      assert {:ok, 1} = Attendance.publish_roster(operator, 73, date, date)
      assert {:ok, []} = Attendance.self_roster(member, 73, date, 7)
      assert {:ok, %{entries: entries, pending: 0}} = Attendance.roster(operator, 73, date, 7)
      assert entries == %{}
    end

    test "clearing an unpublished draft removes it", %{
      employee: employee,
      operator: operator
    } do
      date = Date.utc_today()

      assert {:ok, _} =
               Attendance.plan_roster_entry(operator, 73, employee.id, date, :rest)

      assert {:ok, nil} =
               Attendance.plan_roster_entry(operator, 73, employee.id, date, :none)

      assert {:ok, %{entries: entries}} = Attendance.roster(operator, 73, date, 1)
      assert entries == %{}
    end

    test "refuses retired shifts, foreign employees and unbounded periods", %{
      scope: scope,
      other_scope: other,
      employee: employee,
      operator: operator
    } do
      day = shift!(operator)
      assert {:ok, _} = Attendance.set_shift_template_status(operator, 73, day.id, "retired")
      date = Date.utc_today()

      assert {:error, :shift_unavailable} =
               Attendance.plan_roster_entry(
                 operator,
                 73,
                 employee.id,
                 date,
                 {:shift, day.id}
               )

      assert {:error, :unauthorized} =
               Attendance.plan_roster_entry(operator, 74, employee.id, date, :rest)

      assert {:error, :unauthorized} =
               Attendance.plan_roster_entry(other, 73, employee.id, date, :rest)

      assert {:error, :unauthorized} =
               Attendance.plan_roster_entry(scope, 73, employee.id, date, :rest)

      assert {:error, :invalid_period} = Attendance.roster(operator, 73, date, 32)

      assert {:error, :invalid_period} =
               Attendance.publish_roster(operator, 73, date, Date.add(date, 31))
    end

    test "publishing records an audit action", %{
      employee: employee,
      operator: operator
    } do
      date = Date.utc_today()

      assert {:ok, _} =
               Attendance.plan_roster_entry(operator, 73, employee.id, date, :rest)

      assert {:ok, 1} = Attendance.publish_roster(operator, 73, date, date)

      assert [%{"entries" => 1}] =
               Repo.all(
                 from(a in "base_audit_actions",
                   where: a.event == "people.attendance.roster_published",
                   select: a.payload
                 )
               )
    end

    test "search narrows the employees shown", %{
      operator: operator
    } do
      assert {:ok, %{employees: [%{name: "Approver Two"}]}} =
               Attendance.roster(operator, 73, Date.utc_today(), 7, query: "approver")
    end
  end

  describe "clocking locations" do
    setup %{operator: operator} do
      {:ok, site} =
        Attendance.create_clocking_location(operator, 73, %{
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
      site: site,
      operator: operator
    } do
      assert {:ok, _} = Attendance.put_rules(operator, 73, %{location_required: true})

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

      assert {:ok, _} = Attendance.set_clocking_location_status(operator, 73, site.id, "retired")

      assert {:error, :outside_clocking_location} =
               Attendance.record_clock(
                 scope,
                 73,
                 employee.id,
                 Map.merge(event, %{event_key: "two", latitude: 3.1395, longitude: 101.687})
               )
    end

    test "self clocking refuses a system scope without an authenticated user", %{
      scope: scope,
      operator: operator
    } do
      assert {:ok, _} =
               Attendance.put_rules(operator, 73, %{
                 self_clock_enabled: true,
                 location_required: true
               })

      assert {:error, :unavailable} =
               Attendance.self_clock(scope, 73, "in", "key", %{
                 latitude: 3.1395,
                 longitude: 101.687
               })
    end

    test "locations are validated and company scoped", %{
      scope: scope,
      other_scope: other,
      operator: operator
    } do
      assert {:error, %Ecto.Changeset{}} =
               Attendance.create_clocking_location(operator, 73, %{
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

    defp submit(member, key, local_at, type \\ "in") do
      Attendance.submit_adjustment(member, 73, %{
        "request_key" => key,
        "event_type" => type,
        "local_at" => local_at,
        "reason" => "Forgot to clock"
      })
    end

    test "approval writes the clock event and projects the day", %{
      scope: scope,
      employee: employee,
      operator: operator,
      member: member
    } do
      at = local_now_minus(3600)
      assert {:ok, request} = submit(member, "k1", at)
      assert request.status == "pending"
      assert {:ok, ^request} = submit(member, "k1", at)
      assert {:error, :request_key_conflict} = submit(member, "k1", at, "out")
      assert {:error, :duplicate_request} = submit(member, "k2", at)

      assert {:error, :unauthorized} = Attendance.pending_adjustments(scope, 73)

      assert {:ok, [%{employee_name: "Employee One (E-1)"}]} =
               Attendance.pending_adjustments(operator, 73)

      assert {:ok, approved} =
               Attendance.decide_adjustment(operator, 73, request.id, :approve, nil)

      assert approved.status == "approved" and approved.decided_by_user_id == 92

      assert %ClockEvent{source: "adjustment", actor_user_id: 92, event_type: "in"} =
               Repo.get!(ClockEvent, approved.applied_clock_event_id)

      assert {:ok, [%{status: "in_progress"}]} = Attendance.list_days(scope, 73, employee.id)

      assert {:error, :not_pending} =
               Attendance.decide_adjustment(operator, 73, request.id, :reject, "no")

      assert {:ok, []} = Attendance.pending_adjustments(operator, 73)

      assert [_] =
               Repo.all(
                 from(a in "base_audit_actions",
                   where: a.event == "people.attendance.adjustment_approved",
                   select: a.id
                 )
               )
    end

    test "approval is exempt from the location requirement", %{
      operator: operator,
      member: member
    } do
      assert {:ok, _} = Attendance.put_rules(operator, 73, %{location_required: true})
      assert {:ok, request} = submit(member, "k1", local_now_minus(600))

      assert {:ok, %{status: "approved"}} =
               Attendance.decide_adjustment(operator, 73, request.id, :approve, nil)
    end

    test "the requester and the employee cannot decide", %{
      scope: scope,
      employee: employee,
      member: member
    } do
      assert {:ok, request} = submit(member, "k1", local_now_minus(600))

      assert {:error, :self_approval} =
               Attendance.decide_adjustment(member, 73, request.id, :approve, nil)

      # Another account linked to the same employee is still the employee.
      UserFixtures.insert_user!(%{
        id: 93,
        company_id: 73,
        employee_id: employee.id,
        email: "second-login@example.com"
      })

      second_login = AuthorizationFixtures.sign_in!(scope, 73, 93, [@approve_capability])

      assert {:error, :self_approval} =
               Attendance.decide_adjustment(second_login, 73, request.id, :approve, nil)
    end

    test "rejection needs a note and cancelled requests are final", %{
      operator: operator,
      member: member
    } do
      assert {:ok, first} = submit(member, "k1", local_now_minus(600))

      assert {:error, :note_required} =
               Attendance.decide_adjustment(operator, 73, first.id, :reject, " ")

      assert {:ok, %{status: "rejected", decision_note: "Not on roster"}} =
               Attendance.decide_adjustment(operator, 73, first.id, :reject, "Not on roster")

      assert {:ok, second} = submit(member, "k2", local_now_minus(900), "out")

      assert {:ok, %{status: "cancelled"}} =
               Attendance.cancel_adjustment(member, 73, second.id)

      assert {:error, :not_pending} =
               Attendance.cancel_adjustment(member, 73, second.id)

      assert {:error, :not_pending} =
               Attendance.decide_adjustment(operator, 73, second.id, :approve, nil)

      assert {:ok, [_, _]} = Attendance.self_adjustments(member, 73)
    end

    test "the request window and future times are refused", %{
      operator: operator,
      member: member
    } do
      assert {:ok, _} = Attendance.put_rules(operator, 73, %{adjustment_window_days: 2})
      assert {:error, :future_time} = submit(member, "k1", local_now_minus(-3600))
      assert {:error, :outside_window} = submit(member, "k2", local_now_minus(3 * 86_400))
      assert {:error, :invalid_time} = submit(member, "k3", "not a time")
    end

    test "the local time uses the company time zone", %{
      operator: operator,
      member: member
    } do
      assert {:ok, _} = Attendance.put_rules(operator, 73, %{timezone: "Asia/Kuala_Lumpur"})
      local = local_now_minus(-8 * 3600 + 3600)
      assert {:ok, request} = submit(member, "k1", local)

      assert DateTime.to_naive(request.proposed_at) == NaiveDateTime.add(local, -8 * 3600)
    end

    test "unlinked accounts and other tenants are refused", %{
      scope: scope,
      other_scope: other,
      operator: operator,
      member: member
    } do
      UserFixtures.insert_user!(%{id: 94, company_id: 73, email: "unlinked@example.com"})

      unlinked = AuthorizationFixtures.sign_in!(scope, 73, 94, [@self_capability])

      assert {:error, :not_linked} =
               Attendance.submit_adjustment(unlinked, 73, %{
                 "request_key" => "x",
                 "event_type" => "in",
                 "local_at" => local_now_minus(60),
                 "reason" => "r"
               })

      assert {:ok, request} = submit(member, "k1", local_now_minus(600))

      # A system scope names no approver, and the operator's grant is for
      # company 73 only.
      assert {:error, :unauthorized} =
               Attendance.decide_adjustment(other, 73, request.id, :approve, nil)

      assert {:error, :unauthorized} =
               Attendance.decide_adjustment(operator, 74, request.id, :approve, nil)
    end

    test "self-service follows the current account link and grant", %{
      scope: scope,
      member: member,
      employee: employee
    } do
      assert {:ok, request} = submit(member, "k1", local_now_minus(600))

      # The link is removed while the page that resolved it stays open.
      assert {:ok, _} = Bilimbi.Core.User.update_user(scope, 73, 91, %{employee_id: nil})
      assert {:error, :not_linked} = submit(member, "k2", local_now_minus(300))
      assert {:error, :not_linked} = Attendance.cancel_adjustment(member, 73, request.id)
      assert {:error, :not_linked} = Attendance.self_adjustments(member, 73)

      assert {:ok, [%{request: %{status: "pending"}}]} =
               Attendance.pending_adjustments(member, 73)

      # Relinked to another employee: the former employee's request is out of reach.
      {:ok, other_employee} =
        Employee.create_employee(scope, 73, %{employee_number: "E-9", full_name: "Employee Nine"})

      assert {:ok, _} =
               Bilimbi.Core.User.update_user(scope, 73, 91, %{employee_id: other_employee.id})

      assert {:error, :not_found} = Attendance.cancel_adjustment(member, 73, request.id)
      assert {:ok, []} = Attendance.self_adjustments(member, 73)

      assert {:ok, _} = Bilimbi.Core.User.update_user(scope, 73, 91, %{employee_id: employee.id})
      :ok = AuthorizationFixtures.revoke!(scope, 73, 91, @self_capability)
      assert {:error, :unauthorized} = Attendance.cancel_adjustment(member, 73, request.id)
      assert {:error, :unauthorized} = submit(member, "k3", local_now_minus(300))
    end
  end
end
