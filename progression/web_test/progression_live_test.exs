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
    assert Bilimbi.People.Progression.Contributions.contributions().menu == []
  end
end
