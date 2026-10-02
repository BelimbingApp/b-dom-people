defmodule Bilimbi.People.ProgressionTest do
  use Bilimbi.Base.Database.DataCase, async: false
  import Bilimbi.People.Progression.Fixtures
  alias Bilimbi.People.{Progression, Performance}

  setup do
    on_exit(&Bilimbi.Base.ModuleRegistry.ContributionRegistry.clear_for_test!/0)
    {:ok, ctx: seed!()}
  end

  test "publication is scoped, attributed, immutable and only effective from its date", %{
    ctx: ctx
  } do
    assert {:error, :unauthorized} = Progression.draft(actor(ctx, :viewer), 73, attrs(ctx))
    assert {:error, :unauthorized} = Progression.draft(actor(ctx, :manager), 74, attrs(ctx))
    assert {:ok, draft} = Progression.draft(actor(ctx, :manager), 73, attrs(ctx))
    assert {:error, :no_published_policy} = Progression.explain(actor(ctx, :employee), 73)
    assert {:error, :not_found} = Progression.publish(actor(ctx, :other, 74), 74, draft.id)
    assert {:ok, published} = Progression.publish(actor(ctx, :manager), 73, draft.id)
    assert published.published_by_user_id == 101
    assert {:error, :already_published} = Progression.publish(actor(ctx, :manager), 73, draft.id)
    assert {:ok, %{explanations: [result]}} = Progression.explain(actor(ctx, :employee), 73)
    assert result.status == :unknown
    assert hd(result.rules).observed_level == nil
    future = Date.add(Date.utc_today(), 1)

    assert {:ok, next} =
             Progression.draft(
               actor(ctx, :manager),
               73,
               attrs(ctx, %{version: 2, effective_from: future})
             )

    assert {:ok, _} = Progression.publish(actor(ctx, :manager), 73, next.id)
    assert {:ok, %{explanations: [result]}} = Progression.explain(actor(ctx, :employee), 73)
    assert result.policy.id == draft.id

    assert_raise Postgrex.Error, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE people_progression_policy_versions SET name = 'changed' WHERE id = $1",
        [draft.id]
      )
    end
  end

  test "duplicate identity and malformed rules are refused", %{ctx: ctx} do
    author = actor(ctx, :manager)
    assert {:ok, _} = Progression.draft(author, 73, attrs(ctx))
    assert {:error, :invariant_refused} = Progression.draft(author, 73, attrs(ctx))

    assert {:error, :invalid_rules} =
             Progression.draft(
               author,
               73,
               attrs(ctx, %{version: 2, rules: %{"competence" => []}})
             )

    assert {:error, :profile_unavailable} =
             Progression.draft(
               author,
               73,
               attrs(ctx, %{
                 version: 2,
                 rules: %{
                   "competence" => [
                     %{
                       "code" => "one",
                       "profile_id" => ctx.profile.id,
                       "profile_version" => 99,
                       "skill_id" => 1,
                       "required_level" => 1
                     }
                   ]
                 }
               })
             )
  end

  test "missing performance follows the published rule and never leaks another employee's reviews",
       %{ctx: ctx} do
    ctx = Bilimbi.People.Performance.WorkflowFixtures.ready!(ctx)
    manager = actor(ctx, :manager)

    {:ok, review} =
      Performance.draft_review(
        manager,
        73,
        Bilimbi.People.Performance.WorkflowFixtures.review_attrs(ctx)
      )

    {:ok, p} = Progression.draft(manager, 73, attrs(ctx, %{rules: performance_rules()}))
    {:ok, _} = Progression.publish(manager, 73, p.id)

    assert {:ok, %{explanations: [%{status: :unknown}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    {:ok, _} = Performance.release_review(actor(ctx, :reviewer), 73, review.id)

    assert {:ok, %{explanations: [%{status: :met, rules: [rule]}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    assert rule.review_id == review.id

    assert {:ok, %{explanations: [%{status: :unknown}]}} =
             Progression.explain(actor(ctx, :peer), 73)

    assert {:error, :unauthorized} = Progression.explain(actor(ctx, :employee), 74)
  end

  test "missing evidence may be explicitly not met", %{ctx: ctx} do
    {:ok, p} =
      Progression.draft(
        actor(ctx, :manager),
        73,
        attrs(ctx, %{rules: performance_rules("not_met")})
      )

    {:ok, _} = Progression.publish(actor(ctx, :manager), 73, p.id)

    assert {:ok, %{explanations: [%{status: :not_met}]}} =
             Progression.explain(actor(ctx, :employee), 73)
  end

  test "skill results use finalized current evidence from the pinned profile", %{ctx: ctx} do
    alias Bilimbi.People.Skills
    alias Bilimbi.People.Performance.WorkflowFixtures, as: PF
    PF.grant!(ctx.scope, :manager, 73, ["people.skills.assessments.submit"])

    PF.grant!(
      ctx.scope,
      :reviewer,
      73,
      ~w(people.skills.assessments.review people.skills.assessments.approve people.skills.assessments.manage)
    )

    {:ok, assessor} = Bilimbi.Base.Authz.scope_actor(actor(ctx, :manager))
    {:ok, reviewer} = Bilimbi.Base.Authz.scope_actor(actor(ctx, :reviewer))
    {:ok, profile} = Skills.get_profile(ctx.scope, 73, ctx.profile.id)
    skill_id = hd(profile.items).skill_id
    {:ok, p} = Progression.draft(actor(ctx, :manager), 73, attrs(ctx))
    {:ok, _} = Progression.publish(actor(ctx, :manager), 73, p.id)

    submit = fn key, level, supersedes ->
      {:ok, assessment} =
        Skills.submit_assessment(assessor, 73, %{
          employee_id: ctx.people.employee.id,
          skill_id: skill_id,
          assessed_level: level,
          evidence: "Attributable observed evidence",
          assessed_on: Date.utc_today(),
          request_key: key,
          supersedes_assessment_id: supersedes
        })

      {:ok, _} = Skills.review_assessment(reviewer, 73, assessment.id, :verify, nil)
      {:ok, _} = Skills.finalize_assessment(reviewer, 73, assessment.id)
      assessment
    end

    first = submit.("first-assessment", 0, nil)

    assert {:ok, %{explanations: [%{status: :not_met}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    submit.("corrected-assessment", 1, first.id)

    assert {:ok, %{explanations: [%{status: :met, rules: [rule]}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    assert rule.observed_level == 1
    {:ok, employee_actor} = Bilimbi.Base.Authz.scope_actor(actor(ctx, :employee))
    assert {:ok, %{scores: [score]}} = Skills.standing(employee_actor, 73)
    assert score.assessment_profile_id == ctx.profile.id
    assert score.assessment_profile_version == 1
  end

  test "publication refuses a backdate per code and allows a same-day correction", %{ctx: ctx} do
    manager = actor(ctx, :manager)
    today = Date.utc_today()
    {:ok, first} = Progression.draft(manager, 73, attrs(ctx))
    {:ok, _} = Progression.publish(manager, 73, first.id)

    {:ok, backdated} =
      Progression.draft(
        manager,
        73,
        attrs(ctx, %{version: 2, effective_from: Date.add(today, -1)})
      )

    assert {:error, :effective_order} = Progression.publish(manager, 73, backdated.id)

    {:ok, correction} =
      Progression.draft(manager, 73, attrs(ctx, %{version: 3, name: "Corrected policy"}))

    assert {:ok, _} = Progression.publish(manager, 73, correction.id)

    assert {:ok, %{explanations: [%{policy: policy}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    assert policy.id == correction.id
  end

  test "different policy codes are selected independently", %{ctx: ctx} do
    manager = actor(ctx, :manager)
    today = Date.utc_today()

    {:ok, older} =
      Progression.draft(
        manager,
        73,
        attrs(ctx, %{code: "policy-a", effective_from: Date.add(today, -5)})
      )

    {:ok, _} = Progression.publish(manager, 73, older.id)
    {:ok, newer} = Progression.draft(manager, 73, attrs(ctx, %{code: "policy-b"}))
    {:ok, _} = Progression.publish(manager, 73, newer.id)
    {:ok, same_day} = Progression.draft(manager, 73, attrs(ctx, %{code: "policy-c"}))
    assert {:ok, _} = Progression.publish(manager, 73, same_day.id)

    {:ok, a_backdate} =
      Progression.draft(
        manager,
        73,
        attrs(ctx, %{code: "policy-a", version: 2, effective_from: Date.add(today, -6)})
      )

    assert {:error, :effective_order} = Progression.publish(manager, 73, a_backdate.id)

    assert {:ok, %{explanations: explanations}} = Progression.explain(actor(ctx, :employee), 73)

    assert Enum.map(explanations, & &1.policy.id) == [older.id, newer.id, same_day.id]
  end

  test "performance evidence uses the chronologically latest released period", %{ctx: ctx} do
    alias Bilimbi.People.Performance.WorkflowFixtures, as: PF
    ctx = PF.ready!(ctx)
    manager = actor(ctx, :manager)
    reviewer = actor(ctx, :reviewer)

    release = fn first, last, outcome ->
      {:ok, t} =
        Performance.propose_target(
          manager,
          73,
          Map.merge(PF.target_attrs(ctx, ctx.definition), %{
            period_start: first,
            period_end: last,
            effective_from: first
          })
        )

      {:ok, _} = Performance.review_target(reviewer, 73, t.id, "Target checked")
      {:ok, t} = Performance.publish_target(reviewer, 73, t.id)

      {:ok, o} =
        Performance.record_observation(manager, 73, %{
          employee_id: ctx.people.employee.id,
          window_start: first,
          window_end: last,
          evidence: "Verified units recorded",
          source_reference: "measurement-#{first}",
          source_version: "1"
        })

      {:ok, review} =
        Performance.draft_review(
          manager,
          73,
          Map.merge(PF.review_attrs(ctx), %{
            period_start: first,
            period_end: last,
            outcome: outcome,
            observation_ids: [o.id],
            target_ids: [t.id]
          })
        )

      {:ok, _} = Performance.release_review(reviewer, 73, review.id)
      review
    end

    release.(~D[2026-01-01], ~D[2026-01-31], "Outcome not accepted")
    later = release.(~D[2026-02-01], ~D[2026-09-30], "Agreed outcome")
    {:ok, p} = Progression.draft(manager, 73, attrs(ctx, %{rules: performance_rules()}))
    {:ok, _} = Progression.publish(manager, 73, p.id)

    assert {:ok, %{explanations: [%{status: :met, rules: [rule]}]}} =
             Progression.explain(actor(ctx, :employee), 73)

    assert rule.review_id == later.id
  end
end
