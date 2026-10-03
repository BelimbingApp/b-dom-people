defmodule Bilimbi.People.Skills.WorkflowTest do
  # The workflows authorize through the host's real Authz, so they run in the
  # Web project like the pages do.
  use BilimbiWeb.ConnCase, async: false

  alias Bilimbi.Base.Repo
  alias Bilimbi.Core.User
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.WorkflowFixtures, as: Fixtures
  alias Ecto.Adapters.SQL

  import Fixtures, only: [actor: 2, actor: 3]

  setup do
    ctx = Fixtures.seed!()
    %{ctx: ctx}
  end

  defp submit(ctx, role, employee, level, extra \\ %{}) do
    Skills.submit_assessment(
      actor(ctx, role),
      73,
      Map.merge(
        %{
          employee_id: ctx.people[employee].id,
          skill_id: ctx.welding.id,
          assessed_level: level,
          evidence: "Observed a supervised weld.",
          request_key: "key-#{System.unique_integer([:positive])}"
        },
        extra
      )
    )
  end

  defp finalize(ctx, employee, level, extra \\ %{}) do
    {:ok, row} = submit(ctx, :lead, employee, level, extra)
    {:ok, _} = Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)
    {:ok, row} = Skills.finalize_assessment(actor(ctx, :hr), 73, row.id)
    row
  end

  describe "submitting" do
    test "snapshots the requirement in force and derives the gap and next review", %{ctx: ctx} do
      assert {:ok, row} = submit(ctx, :lead, :one, 1, %{assessed_on: "2026-09-01"})

      assert %{
               status: "pending_review",
               required_level: 2,
               assessed_level: 1,
               gap: 1,
               criticality: "critical",
               mandatory: true,
               priority_multiplier: 3,
               priority_score: 3,
               result_band: "minor_gap",
               next_due_on: ~D[2027-03-01]
             } = row

      assert row.profile_id == ctx.profile.id
      assert row.scale_id == ctx.scale.id

      assert {:ok, [%{decision: "submitted", actor_user_id: 102}]} =
               Skills.assessment_decisions(actor(ctx, :hr), 73, row.id)
    end

    test "a validity date, not the skill's interval, sets the next review", %{ctx: ctx} do
      assert {:ok, %{next_due_on: ~D[2030-01-01], valid_until: ~D[2030-01-01]}} =
               submit(ctx, :lead, :one, 2, %{valid_until: "2030-01-01"})
    end

    test "the company's default interval applies to a skill with none", %{ctx: ctx} do
      {:ok, _} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{default_reassessment_months: 3})
      {:ok, profile} = Skills.get_profile(ctx.scope, 73, ctx.profile.id)
      assert profile.status == "published"

      {:ok, welding} =
        Skills.update_skill(Fixtures.hr_scope(ctx), 73, ctx.welding.id, %{reassessment_months: nil})

      assert welding.reassessment_months == nil

      assert {:ok, %{next_due_on: due}} =
               submit(ctx, :lead, :one, 2, %{assessed_on: "2026-01-31"})

      assert due == ~D[2026-04-30]
    end

    test "policy multipliers are snapshotted on each assessment", %{ctx: ctx} do
      {:ok, old} = submit(ctx, :lead, :one, 0)
      {:ok, _} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{multiplier_critical: 5})
      {:ok, new} = submit(ctx, :lead, :two, 0)

      assert old.priority_multiplier == 3 and old.priority_score == 6
      assert new.priority_multiplier == 5 and new.priority_score == 10
    end

    test "refuses what has no requirement, level, evidence or valid date", %{ctx: ctx} do
      assert {:error, :no_requirement} =
               submit(ctx, :lead, :one, 1, %{skill_id: ctx.inspection.id})

      assert {:error, :level_not_on_scale} = submit(ctx, :lead, :one, 9)
      assert {:error, :invalid_assessment} = submit(ctx, :lead, :one, 1, %{evidence: "  "})

      assert {:error, :future_assessment} =
               submit(ctx, :lead, :one, 1, %{assessed_on: "2999-01-01"})

      assert {:error, :invalid_validity} =
               submit(ctx, :lead, :one, 1, %{assessed_on: "2026-09-01", valid_until: "2026-08-01"})

      assert {:error, :skill_unavailable} = submit(ctx, :lead, :one, 1, %{skill_id: 999_999})
      assert {:ok, _} = Skills.set_skill_active(Fixtures.hr_scope(ctx), 73, ctx.welding.id, false)
      assert {:error, :skill_unavailable} = submit(ctx, :lead, :one, 1)
    end

    test "a request key replays the same assessment and refuses a different one", %{ctx: ctx} do
      assert {:ok, first} = submit(ctx, :lead, :one, 1, %{request_key: "same"})
      assert {:ok, again} = submit(ctx, :lead, :one, 1, %{request_key: "same"})
      assert again.id == first.id
      assert {:error, :key_conflict} = submit(ctx, :lead, :one, 2, %{request_key: "same"})

      assert {:ok, rows} = Skills.list_assessments(actor(ctx, :hr), 73)
      assert length(rows) == 1
    end

    test "reach: the reporting line, company-wide holders, never oneself or another company",
         %{ctx: ctx} do
      assert {:ok, _} = submit(ctx, :lead, :one, 1)
      assert {:error, :out_of_reach} = submit(ctx, :lead, :outsider, 1)
      assert {:error, :out_of_reach} = submit(ctx, :lead, :manager, 1)
      assert {:error, :self_assessment} = submit(ctx, :lead, :lead, 1)
      assert {:ok, _} = submit(ctx, :hr, :outsider, 1)
      assert {:error, :self_assessment} = submit(ctx, :hr, :hr, 1)
      assert {:error, :out_of_reach} = submit(ctx, :outsider, :one, 1)

      # A company-wide holder of another company cannot reach into this one, and
      # an actor without the capability is refused outright.
      assert {:error, reason} =
               Skills.submit_assessment(actor(ctx, :other, 74), 73, %{
                 employee_id: ctx.people.one.id,
                 skill_id: ctx.welding.id,
                 assessed_level: 1,
                 evidence: "x",
                 request_key: "cross"
               })

      assert reason in [:unauthorized, :not_found]
      assert {:error, :unauthorized} = submit(ctx, :one, :two, 1)
      assert {:error, :unauthorized} = submit(ctx, :manager, :lead, 1)
    end
  end

  describe "review and finalization" do
    test "an independent reviewer verifies and a finalizer finalizes, refreshing the score",
         %{ctx: ctx} do
      {:ok, row} = submit(ctx, :lead, :one, 1)

      assert {:error, :not_verified} = Skills.finalize_assessment(actor(ctx, :hr), 73, row.id)

      assert {:error, :out_of_reach} =
               Skills.review_assessment(actor(ctx, :outsider), 73, row.id, :verify, nil)

      assert {:ok, %{status: "verified", reviewed_by_user_id: 101}} =
               Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)

      assert {:error, :not_pending} =
               Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)

      assert {:ok, []} = Skills.gaps(actor(ctx, :hr), 73)

      assert {:ok, %{status: "finalized", finalized_by_user_id: 105}} =
               Skills.finalize_assessment(actor(ctx, :hr), 73, row.id)

      assert {:ok, [gap]} = Skills.gaps(actor(ctx, :hr), 73)

      assert %{
               employee_id: employee_id,
               current_level: 1,
               required_level: 2,
               gap: 1,
               state: :current,
               result_band: "minor_gap"
             } = gap

      assert employee_id == ctx.people.one.id

      assert {:ok, decisions} = Skills.assessment_decisions(actor(ctx, :hr), 73, row.id)
      assert Enum.map(decisions, & &1.decision) == ~w(submitted verified finalized)
    end

    test "the assessor and the assessed employee never decide", %{ctx: ctx} do
      Fixtures.grant!(
        ctx.scope,
        :lead,
        73,
        ~w(people.skills.assessments.review people.skills.assessments.approve)
      )

      Fixtures.grant!(
        ctx.scope,
        :one,
        73,
        ~w(people.skills.assessments.review people.skills.assessments.approve people.skills.assessments.view)
      )

      {:ok, row} = submit(ctx, :lead, :one, 1)

      assert {:error, :self_approval} =
               Skills.review_assessment(actor(ctx, :lead), 73, row.id, :verify, nil)

      assert {:error, :out_of_reach} =
               Skills.review_assessment(actor(ctx, :one), 73, row.id, :verify, nil)

      {:ok, _} = Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)
      assert {:error, :self_approval} = Skills.finalize_assessment(actor(ctx, :lead), 73, row.id)
      assert {:error, :self_approval} = Skills.finalize_assessment(actor(ctx, :one), 73, row.id)
    end

    test "a reviewer must reach the employee", %{ctx: ctx} do
      {:ok, row} = submit(ctx, :hr, :outsider, 1)

      assert {:error, :out_of_reach} =
               Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)
    end

    test "a return needs a note and only the original assessor corrects it, once", %{ctx: ctx} do
      {:ok, row} = submit(ctx, :lead, :one, 0)

      assert {:error, :note_required} =
               Skills.review_assessment(actor(ctx, :manager), 73, row.id, :return, " ")

      assert {:ok, %{status: "returned", review_note: "Evidence is thin."}} =
               Skills.review_assessment(
                 actor(ctx, :manager),
                 73,
                 row.id,
                 :return,
                 "Evidence is thin."
               )

      assert {:ok, %{returned: [returned]}} = Skills.assessment_queue(actor(ctx, :lead), 73)
      assert returned.id == row.id

      correction = %{supersedes_assessment_id: row.id, evidence: "Now with a sample."}
      assert {:error, :not_original_assessor} = submit(ctx, :hr, :one, 1, correction)
      assert {:ok, fixed} = submit(ctx, :lead, :one, 1, correction)
      assert fixed.supersedes_assessment_id == row.id
      assert {:error, :already_superseded} = submit(ctx, :lead, :one, 1, correction)

      assert {:ok, %{returned: []}} = Skills.assessment_queue(actor(ctx, :lead), 73)

      assert {:error, :not_supersedable} =
               submit(ctx, :lead, :two, 1, %{supersedes_assessment_id: row.id})

      assert {:error, :not_supersedable} =
               submit(ctx, :lead, :one, 1, %{supersedes_assessment_id: fixed.id})
    end

    test "a finalized assessment is a fact: the database refuses edits and deletes", %{ctx: ctx} do
      row = finalize(ctx, :one, 2)

      assert_raise Postgrex.Error, ~r/immutable|cannot become/, fn ->
        SQL.query!(
          Repo,
          "UPDATE people_skill_assessments SET evidence = 'edited' WHERE id = $1",
          [row.id]
        )
      end

      assert_raise Postgrex.Error, ~r/never deleted/, fn ->
        SQL.query!(Repo, "DELETE FROM people_skill_assessments WHERE id = $1", [row.id])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        SQL.query!(Repo, "UPDATE people_skill_assessment_decisions SET note = 'x'", [])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        SQL.query!(Repo, "DELETE FROM people_skill_assessment_decisions", [])
      end
    end

    test "the database enforces independence and a finalized source for scores", %{ctx: ctx} do
      {:ok, row} = submit(ctx, :lead, :one, 1)

      assert_raise Postgrex.Error, ~r/people_skill_assessments_independent|violates check/, fn ->
        SQL.query!(
          Repo,
          """
          UPDATE people_skill_assessments SET status = 'verified', reviewed_by_user_id = 102,
            reviewed_at = now() WHERE id = $1
          """,
          [row.id]
        )
      end

      assert_raise Postgrex.Error, ~r/mirrors a finalized|violates foreign key/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO people_skill_scores (tenant_id, company_id, employee_id, skill_id,
            assessment_id, profile_id, required_level, current_level, gap, criticality, mandatory,
            priority_score, assessed_on, next_due_on, inserted_at, updated_at)
          SELECT tenant_id, company_id, employee_id, skill_id, id, profile_id, required_level,
            assessed_level, gap, criticality, mandatory, priority_score, assessed_on, next_due_on,
            now(), now() FROM people_skill_assessments WHERE id = $1
          """,
          [row.id]
        )
      end
    end

    test "the current score follows the newest finalized assessment and finalized corrections",
         %{ctx: ctx} do
      first = finalize(ctx, :one, 1, %{assessed_on: "2026-06-01"})
      assert [%{current_level: 1, assessment_id: first_id}] = scores(ctx, :one)
      assert first_id == first.id

      second = finalize(ctx, :one, 2, %{assessed_on: "2026-07-01"})
      assert [%{current_level: 2, gap: 0, assessment_id: second_id}] = scores(ctx, :one)
      assert second_id == second.id
      assert {:ok, []} = Skills.gaps(actor(ctx, :hr), 73)

      # A finalized correction of the older assessment does not displace a newer one.
      # A correction of the newest replaces it even though it carries an earlier date.
      fix =
        finalize(ctx, :one, 0, %{assessed_on: "2026-06-15", supersedes_assessment_id: second.id})

      assert [%{current_level: 0, assessment_id: fix_id}] = scores(ctx, :one)
      assert fix_id == fix.id
    end

    defp scores(ctx, employee) do
      {:ok, standing} = Skills.standing(actor(ctx, employee), 73)
      standing.scores
    end
  end

  describe "reading" do
    test "the register and gaps stay within the actor's reach", %{ctx: ctx} do
      finalize(ctx, :one, 0)
      {:ok, outside} = submit(ctx, :hr, :outsider, 0)

      assert {:ok, lead_rows} = Skills.list_assessments(actor(ctx, :lead), 73)
      assert Enum.map(lead_rows, & &1.employee_id) == [ctx.people.one.id]

      assert {:ok, hr_rows} = Skills.list_assessments(actor(ctx, :hr), 73)
      assert length(hr_rows) == 2

      assert {:ok, [gap]} = Skills.gaps(actor(ctx, :lead), 73)
      assert gap.employee_name =~ "Employee One"

      assert {:error, :unauthorized} = Skills.list_assessments(actor(ctx, :one), 73)
      assert {:error, :unauthorized} = Skills.list_assessments(actor(ctx, :hr, 74), 74)
      assert {:error, :out_of_reach} = Skills.coverage(actor(ctx, :lead), 73)

      assert {:error, :not_found} =
               Skills.assessment_decisions(actor(ctx, :lead), 73, outside.id)
    end

    test "an employee sees only their own standing", %{ctx: ctx} do
      finalize(ctx, :one, 1)
      assert {:ok, %{scores: [score]}} = Skills.standing(actor(ctx, :one), 73)
      assert score.skill_name == "Welding" and score.current_level == 1
      assert {:ok, %{scores: []}} = Skills.standing(actor(ctx, :two), 73)
      assert {:error, :unauthorized} = Skills.standing(%{actor(ctx, :hr) | type: :agent}, 73)
    end

    test "coverage counts working holders at their required level against the minimum", %{
      ctx: ctx
    } do
      assert {:ok, [%{holders: 0, minimum: 2, covered: false}]} =
               Skills.coverage(actor(ctx, :hr), 73)

      finalize(ctx, :one, 2)
      assert {:ok, [%{holders: 1, covered: false}]} = Skills.coverage(actor(ctx, :hr), 73)
      finalize(ctx, :two, 3)
      assert {:ok, [%{holders: 2, covered: true}]} = Skills.coverage(actor(ctx, :hr), 73)

      {:ok, _} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{backup_minimum: 3})

      assert {:ok, [%{holders: 2, minimum: 3, covered: false}]} =
               Skills.coverage(actor(ctx, :hr), 73)
    end
  end

  describe "reassessment requests" do
    test "a team lead requests once per employee and skill for someone in reach", %{ctx: ctx} do
      assert {:error, :no_score} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 "Doubt"
               )

      finalize(ctx, :one, 2)

      assert {:error, :reason_required} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 " "
               )

      assert {:error, :out_of_reach} =
               Skills.request_reassessment(
                 actor(ctx, :manager),
                 73,
                 ctx.people.outsider.id,
                 ctx.welding.id,
                 "Doubt"
               )

      assert {:error, :self_request} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.lead.id,
                 ctx.welding.id,
                 "Doubt"
               )

      assert {:error, :unauthorized} =
               Skills.request_reassessment(
                 actor(ctx, :one),
                 73,
                 ctx.people.two.id,
                 ctx.welding.id,
                 "Doubt"
               )

      assert {:ok, request} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 "Rework seen"
               )

      assert request.due_on == Date.add(Date.utc_today(), 30)

      assert {:error, :already_open} =
               Skills.request_reassessment(
                 actor(ctx, :manager),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 "Again"
               )

      assert {:ok, [pending]} = Skills.pending_reassessments(actor(ctx, :lead), 73)
      assert pending.employee_name =~ "Employee One"
      assert {:ok, [_]} = Skills.pending_reassessments(actor(ctx, :hr), 73)
      assert {:ok, []} = Skills.pending_reassessments(actor(ctx, :manager), 73)

      assert {:ok, %{status: "cancelled"}} =
               Skills.cancel_reassessment(actor(ctx, :lead), 73, request.id)

      assert {:error, :not_pending} =
               Skills.cancel_reassessment(actor(ctx, :lead), 73, request.id)

      assert {:ok, _} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 "Next"
               )
    end

    test "the due window is a company policy", %{ctx: ctx} do
      finalize(ctx, :one, 2)
      {:ok, _} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{reassessment_due_days: 10})

      assert {:ok, request} =
               Skills.request_reassessment(
                 actor(ctx, :lead),
                 73,
                 ctx.people.one.id,
                 ctx.welding.id,
                 "Soon"
               )

      assert request.due_on == Date.add(Date.utc_today(), 10)
    end

    test "performing submits a normal assessment and never moves the score itself", %{ctx: ctx} do
      finalize(ctx, :one, 2)

      {:ok, request} =
        Skills.request_reassessment(
          actor(ctx, :lead),
          73,
          ctx.people.one.id,
          ctx.welding.id,
          "Doubt"
        )

      assert {:error, :unauthorized} =
               Skills.perform_reassessment(actor(ctx, :lead), 73, request.id, %{
                 assessed_level: 0,
                 evidence: "x"
               })

      assert {:error, :invalid_assessment} =
               Skills.perform_reassessment(actor(ctx, :hr), 73, request.id, %{assessed_level: 0})

      assert {:ok, %{request: %{status: "performed"}, assessment: assessment}} =
               Skills.perform_reassessment(actor(ctx, :hr), 73, request.id, %{
                 assessed_level: 0,
                 evidence: "Failed the practical check."
               })

      assert assessment.status == "pending_review"
      assert [%{current_level: 2}] = scores(ctx, :one)

      assert {:error, :not_pending} =
               Skills.perform_reassessment(actor(ctx, :hr), 73, request.id, %{
                 assessed_level: 0,
                 evidence: "x"
               })

      # HR performed the reassessment, so a different person finalizes it.
      Fixtures.grant!(ctx.scope, :manager, 73, ["people.skills.assessments.approve"])
      {:ok, _} = Skills.review_assessment(actor(ctx, :manager), 73, assessment.id, :verify, nil)
      {:ok, _} = Skills.finalize_assessment(actor(ctx, :manager), 73, assessment.id)
      assert [%{current_level: 0}] = scores(ctx, :one)
    end
  end

  describe "development actions" do
    setup %{ctx: ctx} do
      {:ok, type} =
        Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{
          code: "coaching",
          name: "Coaching",
          requires_provider: true
        })

      {:ok, plain} = Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{code: "reading", name: "Reading"})
      %{type: type, plain: plain}
    end

    defp propose(ctx, type, assessment_id, extra \\ %{}) do
      Skills.propose_action(
        actor(ctx, :hr),
        73,
        Map.merge(
          %{
            assessment_id: assessment_id,
            action_type_id: type.id,
            objective: "Reach the required level.",
            intervention: "Weekly supervised practice.",
            expected_evidence: "A passed practical check.",
            owner_employee_id: ctx.people.lead.id,
            coordinator_employee_id: ctx.people.hr.id,
            provider_employee_id: ctx.people.lead.id,
            start_on: Date.to_iso8601(Date.utc_today()),
            due_on: Date.to_iso8601(Date.add(Date.utc_today(), 30)),
            request_key: "action-#{System.unique_integer([:positive])}"
          },
          extra
        )
      )
    end

    test "proposes from the current gap with a priority snapshot", %{ctx: ctx, type: type} do
      assessed = finalize(ctx, :one, 0)
      assert {:ok, action} = propose(ctx, type, assessed.id)

      assert %{
               status: "proposed",
               closure: "open",
               starting_level: 0,
               target_level: 2,
               gap_at_start: 2,
               criticality: "critical",
               mandatory: true,
               priority_score: 6,
               source_assessment_id: source
             } = action

      assert source == assessed.id
      assert action.employee_name == "Employee One"
      assert action.priority_explanation =~ "Score 6 = gap 2 x critical multiplier 3"
      assert {:error, :already_proposed} = propose(ctx, type, assessed.id)

      {:ok, _} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{multiplier_critical: 4})
      assert {:ok, [listed]} = Skills.list_actions(actor(ctx, :hr), 73)
      assert listed.priority_score == 6
    end

    test "a met requirement is not actionable and only the current assessment counts", %{
      ctx: ctx,
      type: type
    } do
      met = finalize(ctx, :one, 2)
      assert {:error, :not_actionable} = propose(ctx, type, met.id)

      older = finalize(ctx, :two, 0)
      _newer = finalize(ctx, :two, 1)
      assert {:error, :not_current} = propose(ctx, type, older.id)

      {:ok, pending} = submit(ctx, :lead, :two, 0)
      assert {:error, :not_actionable} = propose(ctx, type, pending.id)
    end

    test "checks people, the type and provider before writing", %{
      ctx: ctx,
      type: type,
      plain: plain
    } do
      assessed = finalize(ctx, :one, 0)

      assert {:error, :provider_required} =
               propose(ctx, type, assessed.id, %{provider_employee_id: nil})

      assert {:error, :type_unavailable} = propose(ctx, %{id: 9_999}, assessed.id)

      assert {:error, :employee_unavailable} =
               propose(ctx, plain, assessed.id, %{owner_employee_id: 999_999})

      assert {:error, :invalid_action} = propose(ctx, plain, assessed.id, %{due_on: "2000-01-01"})
      assert {:error, :invalid_action} = propose(ctx, plain, assessed.id, %{objective: ""})
      assert {:error, :unauthorized} = Skills.propose_action(actor(ctx, :lead), 73, %{})
      assert {:ok, _} = propose(ctx, plain, assessed.id)
    end

    test "manual proposals need a reason and the same request key replays", %{
      ctx: ctx,
      plain: plain
    } do
      manual = %{
        employee_id: ctx.people.two.id,
        skill_id: ctx.welding.id,
        starting_level: 1,
        target_level: 3,
        criticality: "essential",
        assessment_id: nil
      }

      assert {:error, :reason_required} = propose(ctx, plain, nil, manual)

      assert {:ok, action} =
               propose(
                 ctx,
                 plain,
                 nil,
                 Map.merge(manual, %{manual_reason: "New assignment.", request_key: "manual-1"})
               )

      assert action.source_assessment_id == nil and action.priority_score == 4

      assert {:ok, same} =
               propose(
                 ctx,
                 plain,
                 nil,
                 Map.merge(manual, %{manual_reason: "New assignment.", request_key: "manual-1"})
               )

      assert same.id == action.id

      assert {:error, :key_conflict} =
               propose(
                 ctx,
                 plain,
                 nil,
                 Map.merge(manual, %{
                   manual_reason: "x",
                   request_key: "manual-1",
                   objective: "Different."
                 })
               )
    end

    test "approval is independent, then the owner progresses and a reassessment closes it", %{
      ctx: ctx,
      plain: plain
    } do
      assessed = finalize(ctx, :one, 0)
      {:ok, action} = propose(ctx, plain, assessed.id)

      assert {:error, :unauthorized} = Skills.approve_action(actor(ctx, :hr), 73, action.id)
      Fixtures.grant!(ctx.scope, :hr, 73, ["people.skills.actions.approve"])
      assert {:error, :self_approval} = Skills.approve_action(actor(ctx, :hr), 73, action.id)

      assert {:ok, %{status: "not_started", approved_by_user_id: 101}} =
               Skills.approve_action(actor(ctx, :manager), 73, action.id)

      assert {:error, :not_proposed} = Skills.approve_action(actor(ctx, :manager), 73, action.id)

      # The owner (lead) may progress it; an unrelated employee may not.
      assert {:error, :unauthorized} = Skills.start_action(actor(ctx, :one), 73, action.id)

      assert {:ok, %{status: "in_progress"}} =
               Skills.start_action(actor(ctx, :lead), 73, action.id)

      assert {:error, :invalid_transition} = Skills.start_action(actor(ctx, :lead), 73, action.id)

      assert {:error, :reason_required} =
               Skills.hold_action(actor(ctx, :lead), 73, action.id, " ")

      assert {:ok, %{status: "on_hold"}} =
               Skills.hold_action(actor(ctx, :lead), 73, action.id, "Waiting for parts")

      assert {:ok, %{status: "in_progress"}} =
               Skills.start_action(actor(ctx, :lead), 73, action.id)

      assert {:error, :invalid_date} =
               Skills.complete_action(actor(ctx, :lead), 73, action.id, "Done", "2000-01-01")

      assert {:error, :evidence_required} =
               Skills.complete_action(
                 actor(ctx, :lead),
                 73,
                 action.id,
                 "",
                 Date.to_iso8601(Date.utc_today())
               )

      due = Date.to_iso8601(Date.add(Date.utc_today(), 7))

      assert {:ok, %{status: "pending_reassessment", closure: "pending_reassessment"}} =
               Skills.complete_action(
                 actor(ctx, :lead),
                 73,
                 action.id,
                 "Ten supervised welds.",
                 due
               )

      # Reassessment: a finalized assessment made after completion closes the action.
      assert {:error, :not_a_reassessment} =
               Skills.link_action_reassessment(actor(ctx, :lead), 73, action.id, assessed.id)

      post = finalize(ctx, :one, 2)

      assert {:ok,
              %{status: "completed", closure: "closed_competent", post_level: 2, improvement: 2}} =
               Skills.link_action_reassessment(actor(ctx, :lead), 73, action.id, post.id)

      assert {:error, :invalid_transition} =
               Skills.cancel_action(actor(ctx, :hr), 73, action.id, "x")

      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        SQL.query!(Repo, "UPDATE people_skill_actions SET objective = 'x' WHERE id = $1", [
          action.id
        ])
      end

      assert {:ok, events} = Skills.action_events(actor(ctx, :hr), 73, action.id)

      assert Enum.map(events, & &1.event_type) ==
               ~w(proposed approved started put_on_hold started intervention_completed reassessment_linked)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        SQL.query!(Repo, "DELETE FROM people_skill_action_events", [])
      end

      assert {:ok, []} = Skills.list_actions(actor(ctx, :hr), 73)
      assert {:ok, [_]} = Skills.list_actions(actor(ctx, :hr), 73, :closed)
    end

    test "a reassessment below target asks for further action; cancelling records a reason", %{
      ctx: ctx,
      plain: plain
    } do
      assessed = finalize(ctx, :one, 0)
      {:ok, action} = propose(ctx, plain, assessed.id)
      {:ok, _} = Skills.approve_action(actor(ctx, :manager), 73, action.id)
      due = Date.to_iso8601(Date.utc_today())
      {:ok, _} = Skills.complete_action(actor(ctx, :hr), 73, action.id, "Trained.", due)
      post = finalize(ctx, :one, 1)

      assert {:ok, %{status: "completed", closure: "further_action_required", improvement: 1}} =
               Skills.link_action_reassessment(actor(ctx, :hr), 73, action.id, post.id)

      other = finalize(ctx, :two, 0)
      {:ok, second} = propose(ctx, plain, other.id)
      assert {:error, :reason_required} = Skills.cancel_action(actor(ctx, :hr), 73, second.id, "")

      assert {:ok, %{status: "cancelled", closure: "cancelled"}} =
               Skills.cancel_action(actor(ctx, :hr), 73, second.id, "Role changed")

      assert {:ok, [_]} =
               Skills.list_actions(actor(ctx, :hr), 73, :closed)
               |> then(fn {:ok, rows} ->
                 {:ok, Enum.filter(rows, &(&1.status == "cancelled"))}
               end)
    end

    test "actions are scoped to the company", %{ctx: ctx, plain: plain} do
      assessed = finalize(ctx, :one, 0)
      {:ok, action} = propose(ctx, plain, assessed.id)
      assert {:error, reason} = Skills.list_actions(actor(ctx, :other, 74), 74)
      assert reason in [:unauthorized, :not_found]
      assert {:error, _} = Skills.approve_action(actor(ctx, :other, 74), 73, action.id)
    end
  end

  describe "reminders" do
    test "overdue reassessments and expiring validity tell the supervisor once per period", %{
      ctx: ctx
    } do
      finalize(ctx, :one, 1, %{assessed_on: "2020-01-01", valid_until: "2020-06-01"})

      assert {:ok, due} = Skills.due_reminders(actor(ctx, :hr), 73)
      rules = due |> Enum.map(& &1.rule) |> Enum.sort()
      assert "overdue_reassessment" in rules and "expiring_certificate" in rules

      overdue = Enum.find(due, &(&1.rule == "overdue_reassessment"))
      assert overdue.recipients == [Fixtures.users().lead]
      expiring = Enum.find(due, &(&1.rule == "expiring_certificate"))

      assert Enum.sort(expiring.recipients) ==
               Enum.sort([Fixtures.users().lead, Fixtures.users().one])

      assert {:error, :unauthorized} = Skills.due_reminders(actor(ctx, :lead), 73)
      assert {:error, :unauthorized} = Skills.issue_reminders(actor(ctx, :lead), 73)
    end

    test "a second run in the same period notifies nobody twice", %{ctx: ctx} do
      finalize(ctx, :one, 1, %{assessed_on: "2020-01-01"})
      today = ~D[2026-09-30]

      assert {:ok, first} = Skills.issue_reminders(actor(ctx, :hr), 73, today)
      assert first.sent >= 1 and first.failed == 0 and first.skipped == 0

      assert {:ok, again} = Skills.issue_reminders(actor(ctx, :hr), 73, today)
      assert again.sent == 0 and again.skipped == first.sent

      assert {:ok, later} = Skills.issue_reminders(actor(ctx, :hr), 73, Date.add(today, 7))
      assert later.sent == first.sent

      assert {:ok, %{sent: 0, failed: 0}} = Skills.retry_reminders(actor(ctx, :hr), 73, today)

      assert {:ok, [_, _] = inbox} = Skills.reminder_inbox(actor(ctx, :lead), 73)
      assert Enum.all?(inbox, &(&1.rule == "overdue_reassessment"))
      assert {:ok, []} = Skills.reminder_inbox(actor(ctx, :one), 73)

      {:ok, notifications} = User.list_notifications(ctx.scope, Fixtures.users().lead)
      assert length(notifications) == 2
    end

    test "overdue actions tell the owner and a coverage gap tells company-wide holders", %{
      ctx: ctx
    } do
      {:ok, plain} = Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{code: "reading", name: "Reading"})
      assessed = finalize(ctx, :one, 0)

      {:ok, action} =
        Skills.propose_action(actor(ctx, :hr), 73, %{
          assessment_id: assessed.id,
          action_type_id: plain.id,
          objective: "Catch up.",
          intervention: "Read the standard.",
          expected_evidence: "A quiz.",
          owner_employee_id: ctx.people.lead.id,
          coordinator_employee_id: ctx.people.hr.id,
          start_on: "2026-01-01",
          due_on: "2026-01-31",
          request_key: "overdue"
        })

      {:ok, _} = Skills.approve_action(actor(ctx, :manager), 73, action.id)
      assert {:ok, due} = Skills.due_reminders(actor(ctx, :hr), 73, ~D[2026-09-30])

      overdue_action = Enum.find(due, &(&1.rule == "overdue_action"))
      assert overdue_action.recipients == [Fixtures.users().lead]
      assert overdue_action.action_id == action.id

      gap = Enum.find(due, &(&1.rule == "coverage_gap"))
      assert Fixtures.users().hr in gap.recipients

      assert {:ok, counts} = Skills.issue_reminders(actor(ctx, :hr), 73, ~D[2026-09-30])
      assert counts.sent >= 2
    end

    test "an item nobody can be told about is counted, not recorded", %{ctx: ctx} do
      Fixtures.grant!(
        ctx.scope,
        :manager,
        73,
        ~w(people.skills.assessments.manage people.skills.assessments.approve)
      )

      {:ok, row} = submit(ctx, :hr, :outsider, 1, %{assessed_on: "2020-01-01"})
      {:ok, _} = Skills.review_assessment(actor(ctx, :manager), 73, row.id, :verify, nil)
      {:ok, _} = Skills.finalize_assessment(actor(ctx, :manager), 73, row.id)

      assert {:ok, due} = Skills.due_reminders(actor(ctx, :hr), 73, ~D[2026-09-30])
      unaddressed = Enum.find(due, &(&1.rule == "overdue_reassessment"))
      assert unaddressed.recipients == []

      assert {:ok, %{unaddressed: unaddressed_count}} =
               Skills.issue_reminders(actor(ctx, :hr), 73, ~D[2026-09-30])

      assert unaddressed_count >= 1

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM people_skill_reminders WHERE employee_id = $1",
                 [ctx.people.outsider.id]
               )
    end

    test "the worker re-checks the operator and queues per company", %{ctx: ctx} do
      alias Bilimbi.People.Skills.ReminderWorker

      assert {:ok, %{"company_id" => 73}} = ReminderWorker.validate_args(%{"company_id" => 73})
      assert {:error, :invalid_reminders} = ReminderWorker.validate_args(%{"company_id" => "73"})
      assert {:error, :invalid_reminders} = Skills.enqueue_reminders(ctx.scope, -1)

      assert {:cancel, :not_authorized} =
               ReminderWorker.handle_job(%{"company_id" => 73}, %{scope: nil})
    end
  end

  describe "policy" do
    test "values are bounded whole numbers stored per company", %{ctx: ctx} do
      assert {:ok, %{reassessment_due_days: 30, backup_minimum: 2}} = Skills.policy(ctx.scope, 73)
      assert {:ok, %{backup_minimum: 5}} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{backup_minimum: 5})
      assert {:ok, %{backup_minimum: 2}} = Skills.policy(ctx.scope, 74)
      assert {:error, :invalid_policy} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{backup_minimum: 0})
      assert {:error, :invalid_policy} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{unknown: 1})
      assert {:error, :invalid_policy} = Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{})

      assert {:error, :invalid_policy} =
               Skills.put_policy(Fixtures.hr_scope(ctx), 73, %{reassessment_due_days: "30"})
    end

    test "action types are company data with unique codes", %{ctx: ctx} do
      assert {:ok, []} = Skills.list_action_types(ctx.scope, 73)

      assert {:ok, type} =
               Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{code: "coaching", name: "Coaching"})

      assert {:error, %Ecto.Changeset{}} =
               Skills.create_action_type(Fixtures.hr_scope(ctx), 73, %{code: "coaching", name: "Again"})

      assert {:ok, %{active: false}} =
               Skills.set_action_type_active(Fixtures.hr_scope(ctx), 73, type.id, false)

      assert {:ok, [_]} = Skills.list_action_types(ctx.scope, 73)
      assert {:ok, []} = Skills.list_action_types(ctx.scope, 74)
      # The HR operator's grants are in company 73 only.
      assert {:error, :unauthorized} =
               Skills.set_action_type_active(Fixtures.hr_scope(ctx), 74, type.id, true)
    end
  end
end
