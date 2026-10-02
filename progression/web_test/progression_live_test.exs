defmodule Bilimbi.People.Progression.Web.ProgressionLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Bilimbi.People.Progression.Fixtures
  alias Bilimbi.People.Progression

  setup do
    {:ok, ctx: seed!(web: true)}
  end

  defp login(conn, id), do: log_in_as(conn, %{"user_id" => id, "company_id" => 73})

  test "operator drafts and confirms publication through the real route", %{conn: conn, ctx: ctx} do
    {:ok, view, _} = conn |> login(101) |> live("/people/progression")
    assert has_element?(view, "#progression-empty")

    html =
      view
      |> form("#progression-draft",
        policy: %{
          code: "policy-one",
          name: "Progression policy",
          version: "1",
          effective_from: Date.to_iso8601(Date.utc_today()),
          profile_id: "#{ctx.profile.id}"
        }
      )
      |> render_submit()

    assert html =~ "Policy draft recorded."
    refute has_element?(view, "#progression-empty")
    view |> element("#progression-policies button", "Publish") |> render_click()
    assert has_element?(view, "#progression-confirm")
    view |> element("button", "Confirm publication") |> render_click()
    refute has_element?(view, "#progression-confirm")
    assert has_element?(view, "#progression-policies", "published")
  end

  test "viewer cannot forge writes and employee sees a meaningful no-policy state", %{conn: conn} do
    {:ok, view, _} = conn |> login(106) |> live("/people/progression")
    refute has_element?(view, "#progression-draft")

    for event <- ["draft", "request_publish", "confirm_publish"],
        do:
          assert(
            render_hook(view, event, %{"id" => "1", "policy" => %{}}) =~ "You cannot do that"
          )

    {:ok, mine, _} = build_conn() |> login(103) |> live("/people/progression/my")
    assert has_element?(mine, "#my-progression-unavailable", "No progression policy")

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             build_conn() |> login(103) |> live("/people/progression")
  end

  test "own explanation cannot be selected by a forged employee parameter", %{
    conn: conn,
    ctx: ctx
  } do
    {:ok, p} = Progression.draft(actor(ctx, :manager), 73, attrs(ctx))
    {:ok, _} = Progression.publish(actor(ctx, :manager), 73, p.id)
    {:ok, view, _} = conn |> login(103) |> live("/people/progression/my?employee_id=999999")
    assert has_element?(view, "#my-progression", "Unknown")

    assert has_element?(
             view,
             "a[href='/people/progression/my'][aria-current='page']",
             "My standing"
           )

    refute has_element?(view, "a[href='/people/progression']")

    assert {:ok, performance, _} =
             view
             |> element("#my-standing-performance a", "Open my performance")
             |> render_click()
             |> follow_redirect(build_conn() |> login(103))

    assert has_element?(performance, "#my-performance-targets")
    assert has_element?(performance, "a[href='/people/progression/my'][aria-current='page']")

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        ctx.scope,
        73,
        :user,
        103,
        "people.performance.self.view",
        false
      )

    {:ok, view, _} = build_conn() |> login(103) |> live("/people/progression/my")
    refute has_element?(view, "#my-standing-performance")
    {:ok, operator, _} = build_conn() |> login(101) |> live("/people/progression")

    assert has_element?(
             operator,
             "a[href='/people/progression'][aria-current='page']",
             "Progression"
           )

    refute has_element?(operator, "a[href='/people/progression/my']")
  end

  test "My standing and own performance follow each self-view grant separately", %{ctx: ctx} do
    set = fn grants ->
      for cap <- ~w(people.progression.self.view people.performance.self.view),
          do:
            {:ok, :stored} =
              Bilimbi.Base.Authz.put_principal_capability(
                ctx.scope,
                73,
                :user,
                103,
                cap,
                cap in grants
              )
    end

    open = fn path -> build_conn() |> login(103) |> live(path) end

    set.(~w(people.progression.self.view people.performance.self.view))
    {:ok, both, _} = open.("/people/progression/my")
    assert has_element?(both, "#my-progression-unavailable")
    assert has_element?(both, "#my-standing-performance a", "Open my performance")
    assert {:ok, _, _} = open.("/people/performance/my")

    set.(~w(people.progression.self.view))
    {:ok, progression_only, _} = open.("/people/progression/my")
    assert has_element?(progression_only, "#my-progression-unavailable")
    assert has_element?(progression_only, "a[href='/people/progression/my']", "My standing")
    refute has_element?(progression_only, "#my-standing-performance")
    assert {:error, {:redirect, %{to: "/dashboard"}}} = open.("/people/performance/my")

    set.(~w(people.performance.self.view))
    assert {:error, {:redirect, %{to: "/dashboard"}}} = open.("/people/progression/my")
    {:ok, performance_only, _} = open.("/people/performance/my")
    assert has_element?(performance_only, "#my-performance-targets")
    refute has_element?(performance_only, "a[href='/people/progression/my']")
    refute has_element?(performance_only, "a[href='/people/performance/my']")

    set.([])
    assert {:error, {:redirect, %{to: "/dashboard"}}} = open.("/people/progression/my")
    assert {:error, {:redirect, %{to: "/dashboard"}}} = open.("/people/performance/my")
    {:ok, dashboard, _} = open.("/dashboard")
    refute has_element?(dashboard, "a[href='/people/progression/my']")
    refute has_element?(dashboard, "a[href='/people/performance/my']")
  end
end
