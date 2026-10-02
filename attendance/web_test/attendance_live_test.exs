defmodule BilimbiWeb.AttendanceLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Attendance.TestFixtures, as: AttendanceFixtures
  alias Bilimbi.People.Attendance

  test "self attendance requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/attendance/my")
  end

  describe "linked account" do
    setup do
      UserFixtures.create_user_tables!()
      SettingsFixtures.create_settings_table!()
      AttendanceFixtures.create_attendance_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
      CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
      {:ok, scope} = Tenancy.scope(41)
      :ok = Employee.ensure_system_types()

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

      grant_capabilities!([
        "people.attendance.self.view",
        "people.attendance.rules.manage",
        "people.attendance.roster.manage"
      ])

      grant_capabilities!(["people.attendance.adjustments.approve"], user_id: 92)
      %{scope: scope, employee: employee}
    end

    test "shows empty self view and a disabled clock until policy enables it", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert render(view) =~ "No clock events yet."
      assert render(view) =~ "Self clocking is off."
      refute has_element?(view, "button[phx-click='clock']")
    end

    test "operator rules are editable for selected company", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/rules")
      assert render(view) =~ "Attendance rules"
      assert has_element?(view, "#attendance-rules-form")

      view
      |> form("#attendance-rules-form",
        timezone: "Etc/UTC",
        enabled: "true",
        max_shift_hours: "12"
      )
      |> render_submit()

      assert render(view) =~ "Attendance rules saved."
    end

    test "linked employee can clock after operator enables it", %{conn: conn} do
      {:ok, scope} = Tenancy.scope(41)
      assert {:ok, _} = Attendance.put_rules(scope, 73, "Etc/UTC", true, 16)
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert has_element?(view, "button[data-clock-type='in']")
      render_click(view, "clock", %{"type" => "in"})
      assert render(view) =~ "Clock event recorded."
      assert render(view) =~ "in progress"
    end

    test "operators manage shift templates and clocking locations", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/rules/shifts")
      assert has_element?(view, "#attendance-shifts-empty")

      view
      |> form("#attendance-shift-form",
        shift: %{
          code: "day",
          name: "Day",
          starts_at: "09:00",
          ends_at: "17:00",
          break_minutes: "60"
        }
      )
      |> render_submit()

      assert render(view) =~ "Shift template added."
      assert render(view) =~ "09:00–17:00"

      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/rules/locations")
      assert has_element?(view, "#attendance-locations-empty")

      view
      |> form("#attendance-location-form",
        location: %{
          code: "hq",
          name: "Head office",
          latitude: "1.5",
          longitude: "103.7",
          radius_meters: "150"
        }
      )
      |> render_submit()

      assert render(view) =~ "Clocking location added."

      assert has_element?(
               view,
               "#attendance-rules-tabs a[aria-current=page]",
               "Clocking locations"
             )
    end

    test "planners draft and publish a week that the employee then sees", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      {:ok, day} =
        Attendance.create_shift_template(scope, 73, %{
          "code" => "day",
          "name" => "Day",
          "starts_at" => "09:00",
          "ends_at" => "17:00"
        })

      today = Date.utc_today() |> Date.to_iso8601()
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/rosters?company_id=73")
      assert render(view) =~ "No unpublished changes this week for this company."
      refute has_element?(view, "#attendance-roster-publish")

      view
      |> element("#roster-cell-#{employee.id}-#{today}")
      |> render_change(%{
        "employee_id" => "#{employee.id}",
        "on_date" => today,
        "value" => "shift:#{day.id}"
      })

      assert render(view) =~ "1 unpublished change this week across the company."
      {:ok, mine, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert has_element?(mine, "#my-attendance-shifts-empty")

      view |> element("#attendance-roster-publish") |> render_click()
      assert render(view) =~ "Published 1 roster change."

      {:ok, mine, _} = conn |> log_in_as() |> live("/people/attendance/my")
      refute has_element?(mine, "#my-attendance-shifts-empty")
      assert render(mine) =~ "Day (day) 09:00–17:00"
    end

    test "an employee request is approved by another account", %{conn: conn} do
      {:ok, mine, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert has_element?(mine, "#my-attendance-requests-empty")

      local_at =
        DateTime.utc_now()
        |> DateTime.add(-3600)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      mine
      |> form("#my-attendance-adjustment-form",
        adjustment: %{event_type: "in", local_at: local_at, reason: "Forgot"}
      )
      |> render_submit()

      assert render(mine) =~ "Adjustment request submitted."
      assert render(mine) =~ "pending"

      approver = log_in_as(conn, session_user(%{"user_id" => 92}))
      {:ok, queue, _} = live(approver, "/people/attendance/approvals")
      assert render(queue) =~ "Employee One (E-1)"

      queue
      |> element("form[id^=adjustment-decision-]")
      |> render_submit(%{"decision" => "reject", "note" => ""})

      assert render(queue) =~ "Add a note explaining the rejection."

      queue
      |> element("form[id^=adjustment-decision-]")
      |> render_submit(%{"decision" => "approve", "note" => ""})

      assert render(queue) =~ "Request approved."
      assert has_element?(queue, "#attendance-approvals-empty")

      {:ok, mine, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert render(mine) =~ "approved"
      assert render(mine) =~ "in progress"
    end

    test "required location keeps clock controls and adjustment fallback", %{
      conn: conn,
      scope: scope
    } do
      assert {:ok, _} =
               Attendance.put_rules(scope, 73, %{
                 self_clock_enabled: true,
                 location_required: true
               })

      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")
      assert has_element?(view, "#my-attendance-location-required")

      assert has_element?(
               view,
               "#my-attendance-clock[phx-hook='Bilimbi.People.Attendance.Web.MyLive.ClockLocation']"
             )

      assert has_element?(view, "button[data-clock-type='in']:not([disabled])")
      assert has_element?(view, "button[data-clock-type='out']:not([disabled])")
      assert has_element?(view, "#my-attendance-adjustment-form")
    end

    test "browser self clock validates inside, outside and missing coordinates", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      {:ok, _} =
        Attendance.put_rules(scope, 73, %{self_clock_enabled: true, location_required: true})

      {:ok, location} =
        Attendance.create_clocking_location(scope, 73, %{
          code: "site-one",
          name: "Clocking location",
          latitude: "1.5",
          longitude: "103.7",
          radius_meters: 150
        })

      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")

      render_click(view, "clock", %{"type" => "in"})
      assert render(view) =~ "A valid location is required"
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)

      render_click(view, "clock", %{"type" => "in", "latitude" => 2.5, "longitude" => 103.7})
      assert render(view) =~ "approved clocking locations. Move to an approved location"
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)

      render_click(view, "clock", %{"type" => "in", "latitude" => 1.5})
      assert render(view) =~ "A valid location is required"
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)

      render_click(view, "clock", %{"type" => "in", "latitude" => 1.5, "longitude" => 103.7})
      assert render(view) =~ "Clock event recorded."
      assert {:ok, [day]} = Attendance.list_days(scope, 73, employee.id)
      assert day.status == "in_progress"
      events = Bilimbi.Base.Repo.all(Bilimbi.People.Attendance.ClockEvent)
      assert [%{clocking_location_id: location_id, actor_user_id: 91, source: "web"}] = events
      assert location_id == location.id
    end

    test "permission refusal and unavailable location write no clock facts", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      {:ok, _} =
        Attendance.put_rules(scope, 73, %{self_clock_enabled: true, location_required: true})

      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")
      render_click(view, "clock_location_error", %{"reason" => "permission_denied"})
      assert render(view) =~ "Location permission was refused"
      assert has_element?(view, "#my-attendance-adjustment-form")
      render_click(view, "clock_location_error", %{"reason" => "unavailable"})
      assert render(view) =~ "Your location is unavailable"
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)
    end

    test "self clock API uses scope identity and refuses revoked authority", %{
      scope: scope,
      employee: employee
    } do
      {:ok, _} = Attendance.put_rules(scope, 73, %{self_clock_enabled: true})
      signed = Bilimbi.Base.Tenancy.Authentication.sign_in(scope, 91, 73)
      actor = %{type: :user, id: 91, company_id: 73}
      assert {:error, :unavailable} = Attendance.self_clock(scope, 73, "in", "system")
      assert {:error, :unavailable} = Attendance.self_clock(signed, 74, "in", "company", %{})

      assert {:error, :unavailable} =
               Attendance.self_clock(signed, 73, %{actor | id: 92}, "in", "forged")

      assert {:ok, :stored} =
               Bilimbi.Base.Authz.put_principal_capability(
                 scope,
                 73,
                 :user,
                 91,
                 "people.attendance.self.view",
                 false
               )

      assert {:error, :unavailable} = Attendance.self_clock(signed, 73, "in", "revoked", %{})
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)
    end

    test "self clock event refreshes authority on an open page", %{
      conn: conn,
      scope: scope,
      employee: employee
    } do
      {:ok, _} = Attendance.put_rules(scope, 73, %{self_clock_enabled: true})
      {:ok, view, _} = conn |> log_in_as() |> live("/people/attendance/my")

      assert {:ok, :stored} =
               Bilimbi.Base.Authz.put_principal_capability(
                 scope,
                 73,
                 :user,
                 91,
                 "people.attendance.self.view",
                 false
               )

      render_click(view, "clock", %{"type" => "in", "latitude" => 1.5, "longitude" => 103.7})
      assert render(view) =~ "Self clocking is unavailable"
      assert {:ok, []} = Attendance.list_days(scope, 73, employee.id)
    end

    test "new pages require their own capability", %{conn: conn} do
      for path <- ["/people/attendance/approvals"] do
        assert {:error, {:redirect, _}} = conn |> log_in_as() |> live(path)
      end

      approver = log_in_as(conn, session_user(%{"user_id" => 92}))

      for path <- [
            "/people/attendance/rosters",
            "/people/attendance/rules/shifts",
            "/people/attendance/rules/locations"
          ] do
        assert {:error, {:redirect, _}} = live(approver, path)
      end
    end
  end
end
