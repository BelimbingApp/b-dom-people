defmodule Bilimbi.People.Performance.Web.PerformanceLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Bilimbi.People.Performance.WorkflowFixtures
  alias Bilimbi.People.Performance

  setup do
    %{ctx: seed!(web: true)}
  end

  defp login(conn, role),
    do:
      log_in_as(conn, %{
        "user_id" =>
          %{manager: 101, reviewer: 102, employee: 103, peer: 104, other: 105, viewer: 106}[role],
        "company_id" => if(role == :other, do: 74, else: 73)
      })

  test "a reviewer starts with a meaningful empty state and can create a measurement", %{
    conn: conn
  } do
    {:ok, view, _} = conn |> login(:manager) |> live("/people/performance")
    assert has_element?(view, "#performance-empty")
    view |> element("a", "KPIs") |> render_click()
    assert has_element?(view, "#definition-form")
    view |> form("#definition-form", record: definition_attrs()) |> render_submit()
    assert has_element?(view, "#performance-definitions", "Measure one")
  end

  test "a viewer cannot forge any write-shaped event", %{conn: conn, ctx: ctx} do
    {:ok, view, _} = conn |> login(:viewer) |> live("/people/performance")
    refute has_element?(view, "#review-form")

    for {event, params} <- [
          {"create_description", %{"record" => %{}}},
          {"create_definition", %{"record" => %{}}},
          {"create_target", %{"record" => %{}}},
          {"create_observation", %{"record" => %{}}},
          {"create_review", %{"record" => %{}}},
          {"review_target", %{"record_id" => "1", "note" => "Forged"}},
          {"request_release", %{"id" => "1"}},
          {"request_publish_target", %{"id" => "1"}},
          {"request_publish_description", %{"id" => "1"}},
          {"confirm_publication", %{}}
        ],
        do: assert(render_hook(view, event, params) =~ "You cannot do that for this company")

    assert {:ok, %{rows: []}} = Performance.reviews(actor(ctx, :manager), 73)
  end

  test "a peer cannot select another author's review, including a forged record id", %{
    conn: conn,
    ctx: ctx
  } do
    ctx = ready!(ctx)
    {:ok, review} = Performance.draft_review(actor(ctx, :manager), 73, review_attrs(ctx))
    {:ok, view, _} = conn |> login(:peer) |> live("/people/performance")
    assert has_element?(view, "#performance-empty")
    render_hook(view, "select", %{"id" => "#{review.id}"})
    refute has_element?(view, "#performance-detail")
    render_hook(view, "select", %{"id" => "invalid"})
    refute has_element?(view, "#performance-detail")
  end

  test "independent release confirms and preserves the original version on the actor's page", %{
    conn: conn,
    ctx: ctx
  } do
    ctx = ready!(ctx)
    {:ok, review} = Performance.draft_review(actor(ctx, :manager), 73, review_attrs(ctx))
    {:ok, view, _} = conn |> login(:reviewer) |> live("/people/performance")
    assert has_element?(view, "#release-#{review.id}")
    refute has_element?(view, "#performance-release-queue-empty")
    view |> element("#release-#{review.id} button", "Release") |> render_click()
    assert has_element?(view, "#performance-publication")
    render_hook(view, "confirm_publication", %{"id" => "999999"})
    refute has_element?(view, "#performance-publication")
    refute has_element?(view, "#release-#{review.id}")
    {:ok, mine, _} = build_conn() |> login(:manager) |> live("/people/performance")
    refute has_element?(mine, "#performance-empty")
    mine |> element("#reviews-#{review.id} button", "Read") |> render_click()
    assert has_element?(mine, "#performance-detail", "Supported by attributable evidence")

    assert has_element?(
             mine,
             "#pinned-evidence-#{ctx.observation.id}",
             "10 verified units recorded"
           )
  end

  test "employees see only their own communicated targets and released review, then respond", %{
    conn: conn,
    ctx: ctx
  } do
    ctx = ready!(ctx)
    {:ok, draft} = Performance.draft_review(actor(ctx, :manager), 73, review_attrs(ctx))
    {:ok, view, _} = conn |> login(:employee) |> live("/people/performance/my")
    assert has_element?(view, "#my-performance-empty")
    assert has_element?(view, "#my-performance-targets", "10 verified units")
    refute has_element?(view, "#my-targets-empty")
    {:ok, _} = Performance.release_review(actor(ctx, :reviewer), 73, draft.id)
    {:ok, view, _} = build_conn() |> login(:employee) |> live("/people/performance/my")
    assert has_element?(view, "#my-review-#{draft.id}", "Supported by attributable evidence")

    view
    |> form("#response-form-#{draft.id}", response: "I disagree with this rationale")
    |> render_submit()

    refute has_element?(view, "#response-form-#{draft.id}")
    assert has_element?(view, "#my-review-#{draft.id}", "I disagree")
    {:ok, peer, _} = build_conn() |> login(:peer) |> live("/people/performance/my")
    assert has_element?(peer, "#my-performance-empty")

    render_hook(peer, "save_response", %{
      "record_id" => "#{draft.id}",
      "response" => "Forged peer response"
    })

    assert has_element?(peer, "#my-performance-empty")
  end

  test "an account without a linked employee receives the unavailable state", %{
    conn: conn,
    ctx: ctx
  } do
    grant!(ctx.scope, :viewer, 73, ["people.performance.self.view"])
    {:ok, view, _} = conn |> login(:viewer) |> live("/people/performance/my")
    assert has_element?(view, "#my-performance-unavailable")
  end

  test "page size survives a reload through URL state", %{conn: conn} do
    {:ok, view, _} = conn |> login(:manager) |> live("/people/performance?page_size=10")

    view
    |> form("#performance-pagination-page-size-form", filters: %{perPage: "50"})
    |> render_change()

    path = assert_patch(view)

    assert URI.decode_query(URI.parse(path).query) == %{
             "page" => "1",
             "page_size" => "50",
             "tab" => "reviews"
           }
  end

  test "capabilities gate routes and employee navigation", %{conn: conn, ctx: ctx} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> login(:viewer) |> live("/people/performance/my")

    {:ok, view, _} = build_conn() |> login(:employee) |> live("/people/performance/my")
    assert has_element?(view, "#my-performance-targets")
    refute has_element?(view, "a[href='/people/performance/my']")
    {:ok, viewer, _} = build_conn() |> login(:viewer) |> live("/people/performance")

    assert has_element?(
             viewer,
             "a[href='/people/performance'][aria-current='page']",
             "Performance reviews"
           )

    refute has_element?(viewer, "a[href='/people/performance/my']")

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        ctx.scope,
        73,
        :user,
        106,
        "people.performance.view",
        false
      )

    {:ok, denied, _} = build_conn() |> login(:viewer) |> live("/dashboard")
    refute has_element?(denied, "a[href='/people/performance']")
    refute has_element?(denied, "a[href='/people/performance/my']")
  end
end
