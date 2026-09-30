defmodule Bilimbi.People.PerformanceTest do
  use Bilimbi.Base.Database.DataCase, async: false
  import Bilimbi.People.Performance.WorkflowFixtures
  alias Bilimbi.People.Performance
  alias Bilimbi.People.Performance.{Description, Review, Observation, Target}
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy

  setup do
    on_exit(&Bilimbi.Base.ModuleRegistry.ContributionRegistry.clear_for_test!/0)
    ctx = seed!()
    {:ok, ctx: ctx}
  end

  test "descriptions pin position and published competency versions and refuse overlaps", %{
    ctx: ctx
  } do
    author = actor(ctx, :manager)
    attrs = description_attrs(ctx)

    assert {:error, :position_version_unavailable} =
             Performance.draft_description(author, 73, %{attrs | position_version: 99})

    assert {:error, :profile_unavailable} =
             Performance.draft_description(author, 73, %{
               attrs
               | competency_links: [%{"id" => ctx.profile.id, "version" => 9}]
             })

    assert {:error, :profile_unavailable} =
             Performance.draft_description(author, 73, %{
               attrs
               | competency_links: [
                   %{"id" => ctx.profile.id, "version" => 1, "wording" => "Copied"}
                 ]
             })

    assert {:ok, draft} = Performance.draft_description(author, 73, attrs)
    assert {:ok, published} = Performance.publish_description(author, 73, draft.id)
    assert published.position_version == 1
    assert {:ok, next} = Performance.draft_description(author, 73, %{attrs | version: 2})

    assert {:error, :overlapping_description} =
             Performance.publish_description(author, 73, next.id)

    assert {:error, :unauthorized} = Performance.draft_description(actor(ctx, :viewer), 73, attrs)
  end

  test "target approval is independent and confidential targets cannot be communicated", %{
    ctx: ctx
  } do
    manager = actor(ctx, :manager)
    reviewer = actor(ctx, :reviewer)
    assert {:ok, definition} = Performance.define_kpi(manager, 73, definition_attrs())

    assert {:ok, proposed} =
             Performance.propose_target(manager, 73, target_attrs(ctx, definition))

    assert {:error, :not_publishable} = Performance.publish_target(reviewer, 73, proposed.id)

    assert {:error, :self_approval} =
             Performance.review_target(manager, 73, proposed.id, "Approve myself")

    assert {:ok, _} = Performance.review_target(reviewer, 73, proposed.id, "Reviewed evidence")
    assert {:error, :self_approval} = Performance.publish_target(manager, 73, proposed.id)
    assert {:ok, target} = Performance.publish_target(reviewer, 73, proposed.id)
    assert target.definition_version == 1
    assert {:ok, own} = Performance.my_records(actor(ctx, :employee), 73)
    assert Enum.map(own.targets, & &1.id) == [target.id]
    assert {:ok, peer} = Performance.my_records(actor(ctx, :peer), 73)
    assert peer.targets == []

    assert {:ok, secret} =
             Performance.propose_target(
               manager,
               73,
               Map.put(target_attrs(ctx, definition), :confidential, true)
             )

    assert {:ok, _} = Performance.review_target(reviewer, 73, secret.id, "Sensitive evidence")
    assert {:error, :not_publishable} = Performance.publish_target(reviewer, 73, secret.id)
  end

  test "cross-company, cross-tenant, unrelated employees and forged ownership are refused", %{
    ctx: ctx
  } do
    manager = actor(ctx, :manager)
    assert {:error, :unauthorized} = Performance.define_kpi(manager, 74, definition_attrs())
    assert {:error, :unauthorized} = Performance.reviews(manager, 75)
    {:ok, other_scope} = Tenancy.scope(42)

    assert {:error, _} =
             Performance.reviews(
               Bilimbi.Base.Tenancy.Authentication.sign_in(other_scope, 101, 73),
               73
             )

    assert {:ok, definition} =
             Performance.define_kpi(
               manager,
               73,
               Map.merge(definition_attrs(), %{actor_user_id: 999, company_id: 74, tenant_id: 42})
             )

    assert definition.actor_user_id == Bilimbi.Base.Tenancy.Scope.actor(manager).user_id

    assert {:error, :out_of_reach} =
             Performance.propose_target(
               manager,
               73,
               Map.put(target_attrs(ctx, definition), :employee_id, ctx.people.peer.id)
             )

    assert {:error, :not_found} =
             Performance.propose_target(
               manager,
               73,
               Map.put(target_attrs(ctx, definition), :employee_id, ctx.people.other.id)
             )

    assert {:error, :out_of_reach} =
             Performance.propose_target(
               manager,
               73,
               Map.put(target_attrs(ctx, definition), :employee_id, ctx.people.manager.id)
             )
  end

  test "drafts need scoped evidence and communicated targets, release refuses author and future cutoff",
       %{ctx: ctx} do
    ctx = ready!(ctx)
    attrs = review_attrs(ctx)
    manager = actor(ctx, :manager)

    assert {:error, :evidence_required} =
             Performance.draft_review(manager, 73, %{attrs | observation_ids: []})

    assert {:error, :not_found} =
             Performance.draft_review(manager, 73, %{attrs | target_ids: [ctx.target.id + 1]})

    assert {:ok, draft} = Performance.draft_review(manager, 73, attrs)
    assert {:error, :self_approval} = Performance.release_review(manager, 73, draft.id)
    assert {:ok, own} = Performance.my_records(actor(ctx, :employee), 73)
    assert own.reviews.rows == []

    assert {:error, :not_found} =
             Performance.respond(actor(ctx, :employee), 73, draft.id, "Premature")

    assert {:ok, released} = Performance.release_review(actor(ctx, :reviewer), 73, draft.id)

    assert released.released_by_user_id ==
             Bilimbi.Base.Tenancy.Scope.actor(actor(ctx, :reviewer)).user_id

    assert {:error, :not_pending} =
             Performance.release_review(actor(ctx, :reviewer), 73, draft.id)

    assert {:ok, future} =
             Performance.draft_review(manager, 73, %{
               attrs
               | cutoff_at: DateTime.add(attrs.cutoff_at, 3600)
             })

    assert {:error, :future_cutoff} =
             Performance.release_review(actor(ctx, :reviewer), 73, future.id)
  end

  test "release and corrections preserve pinned evidence, rationale and employee response", %{
    ctx: ctx
  } do
    ctx = ready!(ctx)
    manager = actor(ctx, :manager)
    employee = actor(ctx, :employee)
    reviewer = actor(ctx, :reviewer)
    attrs = review_attrs(ctx)
    {:ok, original} = Performance.draft_review(manager, 73, attrs)
    {:ok, _} = Performance.release_review(reviewer, 73, original.id)
    assert {:ok, _} = Performance.respond(employee, 73, original.id, "I dispute this outcome")

    assert {:error, :not_found} =
             Performance.respond(actor(ctx, :peer), 73, original.id, "Another employee")

    assert {:error, :invariant_refused} =
             Performance.respond(employee, 73, original.id, "Duplicate")

    assert {:ok, corrected_evidence} =
             Performance.correct_observation(manager, 73, ctx.observation.id, %{
               evidence: "Corrected measured evidence",
               source_version: "2",
               change_reason: "Source corrected"
             })

    assert corrected_evidence.supersedes_id == ctx.observation.id

    assert {:error, :already_corrected} =
             Performance.correct_observation(manager, 73, ctx.observation.id, %{
               evidence: "Another fork",
               source_version: "3",
               change_reason: "Fork"
             })

    # A late correction cannot enter the original cutoff. Preserve the original
    # evidence version when only the review rationale changes.
    assert {:ok, next} =
             Performance.correct_review(
               manager,
               73,
               original.id,
               Map.merge(attrs, %{
                 rationale: "Reconsidered outcome",
                 change_reason: "Employee dispute"
               })
             )

    assert next.version == 2
    assert {:ok, _} = Performance.release_review(reviewer, 73, next.id)
    assert {:ok, old} = Performance.review(manager, 73, original.id)
    assert old.rationale == attrs.rationale
    assert hd(old.observations).evidence == ctx.observation.evidence
    assert hd(old.responses).response == "I dispute this outcome"
    assert {:ok, mine} = Performance.my_records(employee, 73)
    assert Enum.map(mine.reviews.rows, & &1.id) == [next.id, original.id]
    assert {:ok, peer} = Performance.reviews(actor(ctx, :peer), 73)
    assert peer.rows == []
    assert {:error, :not_found} = Performance.review(actor(ctx, :peer), 73, original.id)

    assert {:error, :already_corrected} =
             Performance.correct_review(
               manager,
               73,
               original.id,
               Map.put(attrs, :change_reason, "Fork")
             )
  end

  test "PostgreSQL refuses mutations of evidence, released rationale and target versions", %{
    ctx: ctx
  } do
    ctx = ready!(ctx)
    {:ok, review} = Performance.draft_review(actor(ctx, :manager), 73, review_attrs(ctx))
    {:ok, _} = Performance.release_review(actor(ctx, :reviewer), 73, review.id)

    for {schema, id, changes} <- [
          {Observation, ctx.observation.id, [evidence: "Overwrite"]},
          {Review, review.id, [rationale: "Overwrite"]},
          {Target, ctx.target.id, [target: "Overwrite"]}
        ] do
      assert {:error, _} =
               Repo.transaction(
                 fn ->
                   row = Repo.get!(schema, id)

                   try do
                     Repo.update!(Ecto.Changeset.change(row, changes))
                   rescue
                     error in Postgrex.Error -> Repo.rollback(error.postgres.code)
                   end
                 end,
                 mode: :savepoint
               )

      assert Repo.get!(schema, id)
    end
  end

  test "revoked grants immediately remove read access and current workforce failures refuse writes",
       %{ctx: ctx} do
    ctx = ready!(ctx)
    manager = actor(ctx, :manager)
    {:ok, _} = Performance.draft_review(manager, 73, review_attrs(ctx))

    {:ok, :stored} =
      Authz.put_principal_capability(
        ctx.scope,
        73,
        :user,
        Bilimbi.Base.Tenancy.Scope.actor(manager).user_id,
        "people.performance.view",
        false
      )

    assert {:error, :unauthorized} = Performance.reviews(manager, 73)

    {:ok, _} =
      Bilimbi.Core.Employee.update_employee(ctx.scope, 73, ctx.people.employee.id, %{
        status: "terminated"
      })

    assert {:error, :not_found} =
             Performance.record_observation(manager, 73, %{
               employee_id: ctx.people.employee.id,
               window_start: Date.utc_today(),
               window_end: Date.utc_today(),
               evidence: "Unavailable workforce",
               source_reference: "source",
               source_version: "1"
             })
  end

  test "target amendments retain approved history and start independent review again", %{ctx: ctx} do
    manager = actor(ctx, :manager)
    reviewer = actor(ctx, :reviewer)
    {:ok, definition} = Performance.define_kpi(manager, 73, definition_attrs())
    attrs = target_attrs(ctx, definition) |> Map.put(:period_end, Date.add(Date.utc_today(), 10))
    {:ok, original} = Performance.propose_target(manager, 73, attrs)
    {:ok, _} = Performance.review_target(reviewer, 73, original.id, "Reviewed")
    {:ok, _} = Performance.publish_target(reviewer, 73, original.id)

    amendment = %{
      target: "Revised target",
      effective_from: Date.add(Date.utc_today(), 1),
      change_reason: "Scope changed"
    }

    assert {:ok, next} = Performance.amend_target(manager, 73, original.id, amendment)
    assert next.version == 2 and next.status == "proposed" and next.supersedes_id == original.id

    assert {:error, :already_corrected} =
             Performance.amend_target(manager, 73, original.id, amendment)

    assert {:ok, own} = Performance.my_records(actor(ctx, :employee), 73)
    assert Enum.map(own.targets, & &1.target) == [original.target]
    assert {:error, :not_publishable} = Performance.publish_target(reviewer, 73, next.id)
    assert {:ok, _} = Performance.review_target(reviewer, 73, next.id, "Amendment checked")
    assert {:ok, _} = Performance.publish_target(reviewer, 73, next.id)
    assert Repo.get!(Target, original.id).target == original.target
  end

  test "a late evidence correction requires a new cutoff without rewriting the released version",
       %{ctx: ctx} do
    ctx = ready!(ctx)
    manager = actor(ctx, :manager)
    attrs = review_attrs(ctx)
    {:ok, original} = Performance.draft_review(manager, 73, attrs)
    {:ok, _} = Performance.release_review(actor(ctx, :reviewer), 73, original.id)
    # The owning test controls recorded time explicitly; no sleeps or caller
    # override of the production clock are needed to prove the cutoff rule.
    late_at = DateTime.add(attrs.cutoff_at, 10)

    late =
      Repo.insert!(%Observation{
        tenant_id: 41,
        company_id: 73,
        actor_user_id: Bilimbi.Base.Tenancy.Scope.actor(manager).user_id,
        employee_id: ctx.people.employee.id,
        window_start: Date.utc_today(),
        window_end: Date.utc_today(),
        evidence: "Late corrected evidence",
        source_reference: "measurement-one",
        source_version: "2",
        supersedes_id: ctx.observation.id,
        change_reason: "Source correction",
        inserted_at: late_at,
        updated_at: late_at
      })

    next_attrs =
      attrs
      |> Map.put(:observation_ids, [late.id])
      |> Map.put(:change_reason, "Late source correction")

    assert {:error, :evidence_outside_window} =
             Performance.correct_review(manager, 73, original.id, next_attrs)

    assert {:ok, next} =
             Performance.correct_review(
               manager,
               73,
               original.id,
               Map.put(next_attrs, :cutoff_at, late_at)
             )

    assert {:ok, draft} = Performance.review(manager, 73, next.id)
    assert hd(draft.observations).evidence == "Late corrected evidence"
    assert {:ok, old} = Performance.review(manager, 73, original.id)
    assert old.cutoff_at == attrs.cutoff_at and hd(old.observations).id == ctx.observation.id
  end

  test "an approver who is the subject never sees the pre-release review about themselves", %{
    ctx: ctx
  } do
    ctx = ready!(ctx)
    subject = actor(ctx, :employee)
    reviewer = actor(ctx, :reviewer)
    grant!(ctx.scope, :employee, 73, ["people.performance.reviews.approve"])
    {:ok, draft} = Performance.draft_review(actor(ctx, :manager), 73, review_attrs(ctx))

    assert {:ok, planning} = Performance.planning_records(subject, 73)
    assert planning.drafts == []
    assert {:error, :not_found} = Performance.review(subject, 73, draft.id)
    assert {:error, :self_approval} = Performance.release_review(subject, 73, draft.id)
    assert {:ok, queue} = Performance.planning_records(reviewer, 73)
    assert Enum.map(queue.drafts, & &1.id) == [draft.id]

    {:ok, _} = Performance.release_review(reviewer, 73, draft.id)
    assert {:ok, mine} = Performance.my_records(subject, 73)
    assert Enum.map(mine.reviews.rows, & &1.id) == [draft.id]
  end

  test "KPI reviewers and approvers never list targets about themselves", %{ctx: ctx} do
    manager = actor(ctx, :manager)
    subject = actor(ctx, :employee)

    grant!(
      ctx.scope,
      :employee,
      73,
      ~w(people.performance.kpis.review people.performance.kpis.approve)
    )

    {:ok, definition} = Performance.define_kpi(manager, 73, definition_attrs())

    {:ok, secret} =
      Performance.propose_target(
        manager,
        73,
        Map.put(target_attrs(ctx, definition), :confidential, true)
      )

    assert {:ok, planning} = Performance.planning_records(subject, 73)
    assert planning.targets == []
    assert {:ok, queue} = Performance.planning_records(actor(ctx, :reviewer), 73)
    assert Enum.map(queue.targets, & &1.id) == [secret.id]
  end

  test "planning lists filter before their bound so newer rows cannot crowd out the actor's set",
       %{ctx: ctx} do
    ctx = ready!(ctx)
    attrs = description_attrs(ctx)

    for version <- 2..101 do
      Repo.insert!(%Description{
        tenant_id: 41,
        company_id: 73,
        actor_user_id: 101,
        status: "draft",
        code: attrs.code,
        version: version,
        position_id: attrs.position_id,
        position_version: attrs.position_version,
        effective_from: attrs.effective_from,
        purpose: attrs.purpose,
        responsibilities: attrs.responsibilities,
        duties: attrs.duties,
        authority: attrs.authority,
        qualifications: attrs.qualifications,
        competency_links: %{"profiles" => attrs.competency_links}
      })
    end

    assert {:ok, planning} = Performance.planning_records(actor(ctx, :viewer), 73)
    assert Enum.map(planning.descriptions, & &1.id) == [ctx.description.id]
  end

  test "a correction submitted without a cutoff keeps the prior cutoff", %{ctx: ctx} do
    ctx = ready!(ctx)
    manager = actor(ctx, :manager)
    attrs = review_attrs(ctx)
    {:ok, original} = Performance.draft_review(manager, 73, attrs)
    {:ok, _} = Performance.release_review(actor(ctx, :reviewer), 73, original.id)

    assert {:ok, next} =
             Performance.correct_review(
               manager,
               73,
               original.id,
               %{attrs | cutoff_at: nil} |> Map.put(:change_reason, "Clarified rationale")
             )

    assert next.cutoff_at == original.cutoff_at
  end

  test "the schema verifier checks the owner's exact temporary structures and canonical predicates" do
    assert :ok =
             Bilimbi.Base.Database.SchemaVerifier.verify(
               Repo,
               Bilimbi.People.Performance.SchemaContract.tables(),
               prefix: temporary_schema!()
             )
  end

  test "performer identity is sealed on scope; system and impersonated writes are refused", %{
    ctx: ctx
  } do
    assert {:error, :unauthorized} = Performance.define_kpi(ctx.scope, 73, definition_attrs())
    scope = actor(ctx, :manager)
    sealed_actor = Bilimbi.Base.Tenancy.Scope.actor(scope)
    forged = %{scope | actor: %{sealed_actor | user_id: 102}}

    assert_raise Bilimbi.Base.Tenancy.ForgedActorError, fn ->
      Performance.define_kpi(forged, 73, definition_attrs())
    end

    {:ok, principal} = Authz.scope_actor(scope)

    assert_raise FunctionClauseError, fn ->
      Performance.define_kpi(principal, 73, definition_attrs())
    end

    impersonated =
      Bilimbi.Base.Tenancy.Authentication.sign_in(ctx.scope, 101, 73,
        impersonator_id: 102,
        impersonation_session_id: "test-borrowed-session"
      )

    assert {:error, :impersonation_refused} =
             Performance.define_kpi(impersonated, 73, definition_attrs())

    assert {:ok, planning} = Performance.planning_records(scope, 73)
    assert planning.definitions == []
  end
end
