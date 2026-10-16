defmodule Bilimbi.People.Workforce.Web.SettingsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.EmploymentOwner
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Workforce.Web.SettingsLive

  setup do
    # Against a Core with the seam, the application registered at boot and
    # Core would claim each new employee at once. These tests start from
    # employees that are still Core-only.
    :ok = EmploymentOwner.unregister()
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    Bilimbi.People.Workforce.TestFixtures.create_workforce_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "an operator changes the company's working statuses", %{conn: conn, scope: scope} do
    grant_capabilities!("people.workforce.settings.manage")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")

    assert has_element?(view, "#workforce-status-probation[checked]")
    assert has_element?(view, "#workforce-status-active[checked]")
    refute has_element?(view, "#workforce-status-terminated[checked]")

    view
    |> form("#workforce-settings-form", %{"statuses" => ["active", "terminated"]})
    |> render_submit()

    assert {:ok, %ReadResult{value: ["active", "terminated"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)

    refute has_element?(view, "#workforce-status-probation[checked]")
    assert has_element?(view, "#workforce-status-terminated[checked]")
    refute has_element?(view, "#workforce-settings-freshness")
  end

  test "non-current working-status reads produce operator feedback" do
    assert SettingsLive.freshness_notice(:current) == nil

    assert SettingsLive.freshness_notice({:stale, ~U[2026-09-01 08:30:00Z]}) ==
             "These working statuses were last confirmed at 2026-09-01 08:30 UTC and may be out of date."

    assert SettingsLive.freshness_notice({:unavailable, :source_offline}) ==
             "The current working statuses are unavailable. Saving replaces them with your selection."
  end

  test "saving no status is refused and keeps the stored value", %{conn: conn, scope: scope} do
    grant_capabilities!("people.workforce.settings.manage")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")

    assert render_submit(view, "save", %{}) =~ "Choose at least one employee status."

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)
  end

  test "the route requires the workforce settings capability", %{conn: conn} do
    assert {:error, {_kind, _redirect}} =
             conn |> log_in_as() |> live(~p"/people/workforce/settings")
  end

  test "a save after the grant is revoked changes nothing", %{conn: conn, scope: scope} do
    grant_capabilities!("people.workforce.settings.manage")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")

    assert {:ok, :stored} =
             Authz.put_principal_capability(
               scope,
               73,
               :user,
               91,
               "people.workforce.settings.manage",
               false
             )

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             render_submit(view, "save", %{"statuses" => ["inactive"]})

    assert {:ok, %ReadResult{value: ["probation", "active"], freshness: :current}} =
             Workforce.working_statuses(scope, 73)
  end

  test "an operator claims the company's employment records from Core HR", %{
    conn: conn,
    scope: scope
  } do
    {:ok, employee} = create_employee!(scope)

    grant_capabilities!([
      "people.workforce.settings.manage",
      "people.workforce.employment.view",
      "people.workforce.employment.manage",
      "admin.person.view"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")

    assert has_element?(view, "#workforce-employment-total", "1")
    assert has_element?(view, "#workforce-employment-unclaimed", "1")

    assert view |> element("#workforce-employment-claim") |> render_click() =~
             "Claimed 1, updated 0 from Core HR, 0 already current."

    assert has_element?(view, "#workforce-employment-people", "1")
    assert has_element?(view, "#workforce-employment-unclaimed", "0")

    assert {:ok, %ReadResult{value: %{source: :people}}} =
             Workforce.employment(signed_in(scope), 73, employee.id)
  end

  test "rows People could not claim are listed with the reason", %{conn: conn, scope: scope} do
    {:ok, employee} = create_employee!(scope)
    {:ok, identity} = Employee.person_identity(scope, employee.id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Bilimbi.Base.Repo.insert!(%Bilimbi.People.Workforce.EmploymentRecord{
      tenant_id: 41,
      company_id: 73,
      legacy_employee_id: 900_001,
      person_id: identity.person_id,
      affiliation_id: identity.affiliation_id,
      employee_number: "X-1",
      employment_type: "full_time",
      status: "active",
      claimed_at: now
    })

    grant_capabilities!([
      "people.workforce.settings.manage",
      "people.workforce.employment.view",
      "people.workforce.employment.manage",
      "admin.person.view"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")
    refute has_element?(view, "#workforce-employment-exceptions")

    assert view |> element("#workforce-employment-claim") |> render_click() =~
             "1 could not be claimed and are listed below."

    assert has_element?(
             view,
             "#workforce-employment-exception-#{employee.id}",
             "Another employee already holds this person's employment."
           )
  end

  test "employment records need their own capabilities", %{conn: conn, scope: scope} do
    {:ok, employee} = create_employee!(scope)
    grant_capabilities!(["people.workforce.settings.manage"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")
    refute has_element?(view, "#workforce-employment-records")

    grant_capabilities!(["people.workforce.employment.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")
    assert has_element?(view, "#workforce-employment-records")
    refute has_element?(view, "#workforce-employment-claim")

    assert render_click(view, "reconcile_employments", %{}) =~
             "You cannot claim employment records here."

    grant_capabilities!(["people.workforce.employment.manage"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/workforce/settings")

    assert view |> element("#workforce-employment-claim") |> render_click() =~
             "Claiming also needs permission to view contacts"

    assert {:ok, %ReadResult{value: %{source: :core_legacy}}} =
             Workforce.employment(signed_in(scope), 73, employee.id)
  end

  defp create_employee!(scope) do
    :ok = Employee.ensure_system_types()

    Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})
  end

  defp signed_in(scope) do
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Reader", email: "r@example.com"})
    grant_capabilities!(["people.workforce.employment.view"], user_id: 92)
    Bilimbi.Base.Tenancy.Authentication.sign_in(scope, 92, 73)
  end
end
