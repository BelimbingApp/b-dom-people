defmodule Bilimbi.People.SkillsAccessTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.{Contributions, Reminder, Reminders, Score}
  alias Bilimbi.People.Skills.TestFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions
  alias Ecto.Adapters.SQL

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{descriptor: %{id: "people/skills"}, payload: Contributions.contributions().settings}
      ])

    AuthorizationFixtures.install_snapshot!("skills-access-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    TestFixtures.create_skill_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)

    supervisor = employee(scope, "E-1", nil)
    subject = employee(scope, "E-2", supervisor.id)
    owner_employee = employee(scope, "E-3", nil)
    unrelated = employee(scope, "E-4", nil)

    # Catalog writes authorize the scope's actor: an operator holds the
    # catalog grant, and the manager user (90) publishes the requirement.
    UserFixtures.insert_user!(%{id: 89, company_id: 73, email: "catalog@example.com"})

    operator =
      AuthorizationFixtures.sign_in!(scope, 73, 89, [
        "people.skills.catalog.manage",
        "people.skills.profiles.publish"
      ])

    %{
      scope: scope,
      operator: operator,
      supervisor: supervisor,
      subject: subject,
      owner_employee: owner_employee,
      unrelated: unrelated,
      skill: skill(operator)
    }
  end

  defp employee(scope, number, supervisor_id) do
    {:ok, employee} =
      Employee.create_employee(scope, 73, %{
        employee_number: number,
        full_name: "Employee #{number}",
        supervisor_id: supervisor_id
      })

    employee
  end

  defp skill(scope, attrs \\ %{}) do
    {:ok, category} = Skills.create_category(scope, 73, %{code: "technical", name: "Technical"})

    {:ok, skill} =
      Skills.create_skill(
        scope,
        73,
        Map.merge(
          %{
            code: "welding",
            name: "Welding",
            definition: "Joins parts to the documented standard.",
            category_id: category.id
          },
          attrs
        )
      )

    skill
  end

  defp user(scope, id, employee_id, capabilities) do
    UserFixtures.insert_user!(%{
      id: id,
      company_id: 73,
      employee_id: employee_id,
      email: "user#{id}@example.com"
    })

    for capability <- capabilities,
        do: UserFixtures.grant_capability!(73, id, "people.skills." <> capability)

    Authz.actor(:user, id, scope, 73)
  end

  defp action_ids(actor) do
    {:ok, rows} = Skills.list_actions(actor, 73)
    Enum.map(rows, & &1.id)
  end

  test "development actions are visible to managers, owners and the supervisor chain", ctx do
    %{scope: scope, subject: subject, supervisor: supervisor} = ctx
    manager = user(scope, 90, nil, ~w(actions.view actions.manage))
    owner = user(scope, 91, ctx.owner_employee.id, ~w(actions.view actions.update))
    lead = user(scope, 92, supervisor.id, ~w(actions.view))
    stranger = user(scope, 93, ctx.unrelated.id, ~w(actions.view actions.update))

    {:ok, type} =
      Skills.create_action_type(ctx.operator, 73, %{code: "coaching", name: "Coaching"})

    {:ok, action} =
      Skills.propose_action(manager, 73, %{
        request_key: "action-1",
        employee_id: subject.id,
        skill_id: ctx.skill.id,
        starting_level: 0,
        target_level: 2,
        criticality: "essential",
        manual_reason: "Observed on the line.",
        action_type_id: type.id,
        owner_employee_id: ctx.owner_employee.id,
        coordinator_employee_id: supervisor.id,
        objective: "Reach the documented standard.",
        intervention: "Paired practice.",
        expected_evidence: "Signed practice record.",
        due_on: Date.add(Date.utc_today(), 30)
      })

    for actor <- [manager, owner, lead] do
      assert action_ids(actor) == [action.id]
      assert {:ok, [%{event_type: "proposed"}]} = Skills.action_events(actor, 73, action.id)
    end

    assert action_ids(stranger) == []
    assert {:error, :not_found} = Skills.action_events(stranger, 73, action.id)
  end

  test "an assessment reader with no linked employee reaches nobody instead of failing", ctx do
    finalizer = user(ctx.scope, 94, nil, ~w(assessments.view assessments.approve))

    assert {:ok, %{review: [], finalize: [], returned: []}} =
             Skills.assessment_queue(finalizer, 73)

    assert {:ok, []} = Skills.list_assessments(finalizer, 73)
    assert {:ok, []} = Skills.gaps(finalizer, 73)
  end

  test "a finalized correction of a returned correction replaces the original score", ctx do
    %{scope: scope, subject: subject, skill: skill} = ctx
    manager = user(scope, 90, nil, ~w(assessments.view assessments.review assessments.approve
                                       assessments.manage profiles.publish))
    assessor = user(scope, 92, ctx.supervisor.id, ~w(assessments.submit))
    today = Date.utc_today()
    requirement(ctx, skill, Date.add(today, -100))

    submit = fn key, level, on, supersedes ->
      {:ok, row} =
        Skills.submit_assessment(assessor, 73, %{
          employee_id: subject.id,
          skill_id: skill.id,
          assessed_level: level,
          evidence: "Observed #{key}.",
          assessed_on: on,
          request_key: key,
          supersedes_assessment_id: supersedes
        })

      row
    end

    original = submit.("original", 1, Date.add(today, -10), nil)
    {:ok, _} = Skills.review_assessment(manager, 73, original.id, :verify, nil)
    {:ok, _} = Skills.finalize_assessment(manager, 73, original.id)

    returned = submit.("returned", 2, Date.add(today, -20), original.id)
    {:ok, _} = Skills.review_assessment(manager, 73, returned.id, :return, "Wrong date.")

    correction = submit.("correction", 2, Date.add(today, -20), returned.id)
    {:ok, _} = Skills.review_assessment(manager, 73, correction.id, :verify, nil)
    {:ok, _} = Skills.finalize_assessment(manager, 73, correction.id)

    assert %Score{assessment_id: assessment_id, current_level: 2} =
             Repo.one(
               from(s in Score, where: s.employee_id == ^subject.id and s.skill_id == ^skill.id)
             )

    assert assessment_id == correction.id
  end

  defp requirement(%{operator: scope} = ctx, skill, effective_from) do
    {:ok, scale} = Skills.create_scale(scope, 73, %{code: "standard", name: "Standard"})

    for {name, level} <- Enum.with_index(~w(None Aware Competent)) do
      {:ok, _} =
        Skills.put_scale_level(scope, 73, scale.id, %{
          level: level,
          name: name,
          anchor: "Observed #{name}",
          authority: "Works at #{name}"
        })
    end

    {:ok, scale} = Skills.publish_scale(scope, 73, scale.id)

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: "base", name: "Base", scale_id: scale.id})

    {:ok, _} =
      Skills.put_item(scope, 73, profile.id, %{
        skill_id: skill.id,
        required_level: 2,
        criticality: "essential",
        weight_percent: 100
      })

    {:ok, _} = Skills.add_selector(scope, 73, profile.id, :company)
    publisher = AuthorizationFixtures.sign_in(ctx.scope, 90, 73)
    {:ok, _} = Skills.publish_profile(publisher, 73, profile.id, effective_from)
  end

  test "coverage gaps are due to a reminder sender without assessment capabilities", ctx do
    critical = skill_in(ctx.operator, "rigging", true)
    sender = user(ctx.scope, 95, nil, ~w(reminders.send))

    assert {:ok, due} = Skills.due_reminders(sender, 73)
    assert Enum.any?(due, &(&1.rule == "coverage_gap" and &1.skill_id == critical.id))
  end

  defp skill_in(scope, code, critical) do
    {:ok, [category]} = Skills.list_categories(scope, 73)

    {:ok, skill} =
      Skills.create_skill(scope, 73, %{
        code: code,
        name: String.capitalize(code),
        definition: "Handles the documented load.",
        category_id: category.id,
        critical: critical
      })

    skill
  end

  test "a retry sends a stalled pending reminder and words it by rule", ctx do
    sender = user(ctx.scope, 95, nil, ~w(reminders.send))
    user(ctx.scope, 91, ctx.subject.id, [])
    user(ctx.scope, 92, ctx.supervisor.id, [])
    today = Date.utc_today()
    ends_on = Date.add(today, 10)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for {recipient, inserted_at} <- [{91, NaiveDateTime.add(now, -3600)}, {92, now}] do
      Repo.insert!(%Reminder{
        tenant_id: 41,
        company_id: 73,
        rule: "expiring_certificate",
        employee_id: ctx.subject.id,
        skill_id: ctx.skill.id,
        period_key: Reminders.period_key("expiring_certificate", today),
        recipient_user_id: recipient,
        due_on: ends_on,
        state: "pending",
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
    end

    assert {:ok, %{sent: 1, failed: 0}} = Skills.retry_reminders(sender, 73)

    assert %{rows: [[data]]} =
             SQL.query!(Repo, "SELECT data FROM notifications WHERE notifiable_id = 91", [])

    assert Jason.decode!(data)["body"] == "Welding validity ends on #{ends_on}."

    assert ["pending"] ==
             Repo.all(from(r in Reminder, where: r.recipient_user_id == 92, select: r.state))
  end
end
