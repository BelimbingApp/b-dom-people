defmodule Bilimbi.People.Skills.Web.AssessmentLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.WorkflowFixtures, as: Fixtures

  import Fixtures, only: [actor: 2]

  @pages ~w(/people/skills/assessments /people/skills/actions /people/skills/my /people/skills/policy)

  setup do
    %{ctx: Fixtures.seed!()}
  end

  defp login(conn, role),
    do: log_in_as(conn, %{"user_id" => Fixtures.users()[role], "company_id" => 73})

  defp finalize(ctx, employee, level) do
    {:ok, row} =
      Skills.submit_assessment(actor(ctx, :lead), 73, %{
        employee_id: ctx.people[employee].id,
        skill_id: ctx.welding.id,
        assessed_level: level,
        evidence: "Observed.",
        request_key: "k-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)
    {:ok, row} = Skills.finalize_assessment(actor(ctx, :hr), 73, row.id)
    row
  end

  test "every page requires authentication and its capability", %{conn: conn} do
    for path <- @pages, do: assert({:error, {:redirect, %{to: "/"}}} = live(conn, path))

    # Employee One holds only the self-view capability.
    for path <- @pages -- ["/people/skills/my"] do
      assert {:error, {_kind, _redirect}} = conn |> login(:one) |> live(path)
    end

    assert {:ok, _view, _html} = conn |> login(:one) |> live("/people/skills/my")
  end

  describe "assessments page" do
    test "shows empty states and the critical skill's missing cover", %{conn: conn} do
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/assessments")

      for id <-
            ~w(#assessment-queue-empty #assessment-register-empty #team-gaps-empty #reassessment-empty),
          do: assert(has_element?(view, id))

      assert has_element?(view, "#coverage", "Welding")
    end

    test "a lead submits, a manager verifies and HR finalizes", %{conn: conn, ctx: ctx} do
      {:ok, lead_view, _} = conn |> login(:lead) |> live("/people/skills/assessments")

      lead_view
      |> form("#assessment-form",
        assessment: %{
          employee_id: ctx.people.one.id,
          skill_id: ctx.welding.id,
          assessed_level: "1",
          evidence: "Weld failed the bend test.",
          method: "Practical"
        }
      )
      |> render_submit()

      assert has_element?(lead_view, "#assessment-register", "Employee One")
      assert has_element?(lead_view, "#assessment-register", "Pending review")
      refute has_element?(lead_view, "#assessment-review-queue")

      {:ok, manager_view, _} =
        build_conn() |> login(:manager) |> live("/people/skills/assessments")

      assert has_element?(manager_view, "#assessment-review-queue", "Weld failed the bend test.")
      refute has_element?(manager_view, "#assessment-form")

      manager_view |> element("#assessment-review-queue button", "Verify") |> render_click()
      refute has_element?(manager_view, "#assessment-review-queue")

      {:ok, hr_view, _} = build_conn() |> login(:hr) |> live("/people/skills/assessments")
      assert has_element?(hr_view, "#assessment-finalize-queue", "Employee One")
      hr_view |> element("#assessment-finalize-queue button", "Finalize") |> render_click()
      assert has_element?(hr_view, "#assessment-register", "Finalized")
      assert has_element?(hr_view, "#team-gaps", "Employee One")
    end

    test "a returned assessment is corrected by its assessor", %{conn: conn, ctx: ctx} do
      {:ok, row} =
        Skills.submit_assessment(actor(ctx, :lead), 73, %{
          employee_id: ctx.people.one.id,
          skill_id: ctx.welding.id,
          assessed_level: 0,
          evidence: "Guess.",
          request_key: "first"
        })

      {:ok, manager_view, _} = conn |> login(:manager) |> live("/people/skills/assessments")

      manager_view
      |> form("#return-form-#{row.id}", %{note: "Needs real evidence."})
      |> render_submit()

      {:ok, view, _} = build_conn() |> login(:lead) |> live("/people/skills/assessments")
      assert has_element?(view, "#assessment-returned-queue", "Needs real evidence.")
      view |> element("#returned-#{row.id} button", "Correct") |> render_click()

      view
      |> form("#assessment-form", assessment: %{assessed_level: "1", evidence: "Sample kept."})
      |> render_submit()

      refute has_element?(view, "#assessment-returned-queue")
      assert has_element?(view, "#assessment-register", "Pending review")
    end

    test "events without the capability are refused and change nothing", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:manager) |> live("/people/skills/assessments")

      assert render_hook(view, "create_assessment", %{
               "assessment" => %{
                 "employee_id" => "#{ctx.people.one.id}",
                 "skill_id" => "#{ctx.welding.id}",
                 "assessed_level" => "1",
                 "evidence" => "x",
                 "request_key" => "forged"
               }
             }) =~ "You cannot do that for this company."

      assert render_hook(view, "finalize_assessment", %{"id" => "1"}) =~ "You cannot do that"

      assert render_hook(view, "perform_reassessment", %{"perform" => %{"request_id" => "1"}}) =~
               "You cannot do that"

      assert {:ok, []} = Skills.list_assessments(actor(ctx, :hr), 73)
    end

    test "reassessments are requested by a lead and performed by HR", %{conn: conn, ctx: ctx} do
      finalize(ctx, :one, 2)
      {:ok, view, _} = conn |> login(:lead) |> live("/people/skills/assessments")

      view
      |> form("#reassessment-form",
        request: %{employee_id: ctx.people.one.id, skill_id: ctx.welding.id, reason: "Rework"}
      )
      |> render_submit()

      assert has_element?(view, "#reassessment-requests", "Employee One")
      refute has_element?(view, "[id^=perform-form]")

      {:ok, hr_view, _} = build_conn() |> login(:hr) |> live("/people/skills/assessments")
      [request] = elem(Skills.pending_reassessments(actor(ctx, :hr), 73), 1)

      hr_view
      |> form("#perform-form-#{request.id}",
        perform: %{assessed_level: "1", evidence: "Re-tested."}
      )
      |> render_submit()

      assert has_element?(hr_view, "#reassessment-empty")
      assert has_element?(hr_view, "#assessment-register", "Pending review")
    end
  end

  describe "actions page" do
    setup %{ctx: ctx} do
      {:ok, type} =
        Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{code: "coaching", name: "Coaching"})

      Fixtures.grant!(ctx.scope, :manager, 73, ["people.skills.actions.view"])
      %{type: type}
    end

    test "starts empty and asks for an action type first", %{conn: conn, ctx: ctx, type: type} do
      {:ok, _} = Skills.set_action_type_active(Fixtures.hr_scope(ctx), 73, type.id, false)
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/actions")
      assert has_element?(view, "#actions-empty")
      assert has_element?(view, "#action-types-empty")
    end

    test "HR proposes from a gap, a manager approves and the owner closes it", %{
      conn: conn,
      ctx: ctx,
      type: type
    } do
      assessed = finalize(ctx, :one, 0)
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/actions")

      view
      |> form("#action-form",
        action: %{
          assessment_id: assessed.id,
          action_type_id: type.id,
          objective: "Reach the level.",
          intervention: "Practice.",
          expected_evidence: "A check.",
          owner_employee_id: ctx.people.lead.id,
          coordinator_employee_id: ctx.people.hr.id,
          due_on: Date.to_iso8601(Date.add(Date.utc_today(), 20))
        }
      )
      |> render_submit()

      [action] = elem(Skills.list_actions(actor(ctx, :hr), 73), 1)
      assert has_element?(view, "#action-status-#{action.id}", "Proposed")
      refute has_element?(view, "#action-#{action.id} button", "Approve")

      {:ok, manager_view, _} = build_conn() |> login(:manager) |> live("/people/skills/actions")
      manager_view |> element("#action-#{action.id} button", "Approve") |> render_click()
      assert has_element?(manager_view, "#action-status-#{action.id}", "Not started")
      refute has_element?(manager_view, "#action-form")
      refute has_element?(manager_view, "#action-#{action.id} button", "Start")

      {:ok, view, _} = build_conn() |> login(:hr) |> live("/people/skills/actions")
      view |> element("#action-#{action.id} button", "Start") |> render_click()
      assert render(view) =~ "In progress"

      view
      |> form("#complete-form-#{action.id}",
        complete: %{
          evidence: "Ten supervised welds.",
          reassessment_due_on: Date.to_iso8601(Date.add(Date.utc_today(), 7))
        }
      )
      |> render_submit()

      assert has_element?(view, "#action-status-#{action.id}", "Pending reassessment")

      post = finalize(ctx, :one, 2)
      render_click(element(view, "#action-#{action.id} button", "History"))
      assert has_element?(view, "#action-history-#{action.id}", "Intervention completed")

      {:ok, view, _} = build_conn() |> login(:hr) |> live("/people/skills/actions")

      view
      |> form("#link-form-#{action.id}", %{assessment_id: post.id})
      |> render_submit()

      refute has_element?(view, "#action-#{action.id}")
      view |> element("button", "Closed") |> render_click()
      assert has_element?(view, "#action-status-#{action.id}", "Completed")
    end

    test "events without the capability are refused", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:manager) |> live("/people/skills/actions")
      assert render_hook(view, "create_action", %{"action" => %{}}) =~ "You cannot do that"
      assert render_hook(view, "start_action", %{"id" => "1"}) =~ "You cannot do that"
      assert {:ok, []} = Skills.list_actions(actor(ctx, :hr), 73)
    end
  end

  describe "my skills page" do
    test "an employee sees their own standing and nobody else's", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:one) |> live("/people/skills/my")
      assert has_element?(view, "#my-skills-empty")
      assert has_element?(view, "#my-actions-empty")

      finalize(ctx, :one, 1)
      finalize(ctx, :two, 2)
      {:ok, view, _} = build_conn() |> login(:one) |> live("/people/skills/my")
      assert has_element?(view, "#my-skills", "Welding")
      assert has_element?(view, "#my-skills", "1 / 2")
      assert render(view) =~ "Minor gap"
    end

    test "an account without a linked employee sees the unavailable state", %{
      conn: conn,
      ctx: ctx
    } do
      UserFixtures.insert_user!(%{id: 91, company_id: 73, email: "operator@example.com"})

      {:ok, :stored} =
        Bilimbi.Base.Authz.put_principal_capability(
          ctx.scope,
          73,
          :user,
          91,
          "people.skills.self.view",
          true
        )

      {:ok, view, _} =
        conn |> log_in_as(%{"user_id" => 91, "company_id" => 73}) |> live("/people/skills/my")

      assert has_element?(view, "#my-skills-unavailable")
    end
  end

  describe "policy page" do
    test "HR saves the policy, adds action types and queues reminders", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/policy")
      assert has_element?(view, "#action-types-none")
      # The critical skill has no holder yet, so its coverage gap is already due.
      assert has_element?(view, "#reminders-due", "Coverage gap")

      view
      |> form("#skills-policy-form",
        policy: %{
          reassessment_due_days: "45",
          default_reassessment_months: "12",
          reminder_window_days: "20",
          backup_minimum: "3",
          multiplier_critical: "4",
          multiplier_essential: "2",
          multiplier_development: "1"
        }
      )
      |> render_submit()

      assert {:ok, %{reassessment_due_days: 45, backup_minimum: 3, multiplier_critical: 4}} =
               Skills.policy(ctx.scope, 73)

      view
      |> form("#action-type-form",
        type: %{code: "coaching", name: "Coaching", requires_provider: "true"}
      )
      |> render_submit()

      assert has_element?(view, "#action-types", "Coaching")
      assert has_element?(view, "#action-types", "needs a provider")

      view |> element("#action-types button", "Deactivate") |> render_click()
      assert has_element?(view, "#action-types", "inactive")

      view |> element("button", "Send due reminders") |> render_click()
      assert render(view) =~ "Reminders queued."
    end

    test "invalid values are refused with a message", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/policy")

      assert render_hook(view, "save_policy", %{"policy" => %{"backup_minimum" => "0"}}) =~
               "Enter whole numbers within the shown limits."

      assert {:ok, %{backup_minimum: 2}} = Skills.policy(ctx.scope, 73)
    end

    test "a policy save after the grant is revoked changes nothing", %{conn: conn, ctx: ctx} do
      {:ok, view, _} = conn |> login(:hr) |> live("/people/skills/policy")
      assert has_element?(view, "#skills-policy-form button", "Save policy")
      {:ok, before} = Skills.policy(ctx.scope, 73)

      values =
        before
        |> Map.put(:backup_minimum, 97)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), to_string(value)} end)

      # The page stays open while an administrator revokes the grant.
      assert {:ok, :stored} =
               Authz.put_principal_capability(
                 ctx.scope,
                 73,
                 :user,
                 Fixtures.users()[:hr],
                 "people.skills.policy.manage",
                 false
               )

      assert render_hook(view, "save_policy", %{"policy" => values}) =~
               "You no longer have permission to change this company"

      assert {:ok, ^before} = Skills.policy(ctx.scope, 73)
      refute has_element?(view, "#skills-policy-form button", "Save policy")
    end

    test "a viewer without the write capabilities is refused", %{conn: conn, ctx: ctx} do
      Fixtures.grant!(ctx.scope, :lead, 73, ["people.skills.policy.manage"])
      {:ok, view, _} = conn |> login(:lead) |> live("/people/skills/policy")
      refute has_element?(view, "#action-type-form")
      refute has_element?(view, "#reminders-due")

      assert render_hook(view, "create_action_type", %{"type" => %{"code" => "x", "name" => "X"}}) =~
               "You cannot change this company"

      assert render_hook(view, "run_reminders", %{}) =~ "You cannot change this company"
      assert {:ok, []} = Skills.list_action_types(ctx.scope, 73)
    end
  end
end
