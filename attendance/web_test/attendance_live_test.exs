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

      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
      grant_capabilities!(["people.attendance.self.view", "people.attendance.rules.manage"])
      :ok
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
      assert has_element?(view, "button[phx-value-type='in']")
      render_click(view, "clock", %{"type" => "in"})
      assert render(view) =~ "Clock event recorded."
      assert render(view) =~ "in progress"
    end
  end
end
