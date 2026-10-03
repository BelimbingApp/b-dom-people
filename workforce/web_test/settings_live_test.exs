defmodule Bilimbi.People.Workforce.Web.SettingsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Workforce.Web.SettingsLive

  setup do
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
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
end
