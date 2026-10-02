defmodule Bilimbi.People.Training.Web.EvaluationLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Repo, Tenancy, Settings}
  alias Bilimbi.Base.Settings.Scope, as: SettingScope
  alias Bilimbi.Core.Company.TestFixtures, as: Companies
  alias Bilimbi.Core.User.TestFixtures, as: Users
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.{TestFixtures, Participation}

  setup %{conn: conn} do
    Users.create_user_tables!()
    TestFixtures.migrate_evaluation_tables!()
    Companies.insert_tenant!(%{id: 41, is_platform_operator: false})
    Companies.insert_tenant!(%{id: 42, is_platform_operator: false})

    for {id, tenant} <- [{73, 41}, {74, 41}, {75, 42}],
        do:
          Companies.insert_company!(%{
            id: id,
            tenant_id: tenant,
            name: "Company #{id}",
            code: "company-#{id}"
          })

    {:ok, identity_scope} = Tenancy.scope(41)

    {:ok, _} =
      Bilimbi.Core.Employee.create_employee_type(identity_scope, 73, %{
        code: "employee_type",
        label: "Employee type"
      })

    {:ok, manager} =
      Bilimbi.Core.Employee.create_employee(identity_scope, 73, %{
        employee_number: "employee-102",
        full_name: "Employee 102",
        employee_type: "employee_type",
        status: "active"
      })

    {:ok, learner} =
      Bilimbi.Core.Employee.create_employee(identity_scope, 73, %{
        employee_number: "employee-101",
        full_name: "Employee 101",
        employee_type: "employee_type",
        status: "active",
        supervisor_id: manager.id
      })

    {:ok, other} =
      Bilimbi.Core.Employee.create_employee(identity_scope, 73, %{
        employee_number: "employee-103",
        full_name: "Employee 103",
        employee_type: "employee_type",
        status: "active"
      })

    assert {learner.id, manager.id, other.id} == {2, 1, 3}

    for {user, employee} <- [{91, 2}, {92, 1}, {93, nil}, {94, nil}, {95, 3}] do
      Users.insert_user!(%{
        id: user,
        company_id: 73,
        employee_id: employee,
        name: "Actor #{user}",
        email: "actor-#{user}@example.test"
      })

      grant_capabilities!("people.training.courses.view", user_id: user)
    end

    grant(91, ~w(requests.submit))
    grant(92, ~w(requests.recommend plans.submit))

    grant(
      93,
      ~w(requests.view requests.review plans.view plans.approve budgets.view budgets.manage)
    )

    grant(94, ~w(requests.view requests.approve))
    scopes = Map.new(91..95, fn id -> {id, scope(conn, id)} end)
    grant(91, ~w(evaluation.submit))
    grant(92, ~w(effectiveness.view effectiveness.answer))

    grant(
      93,
      ~w(effectiveness.view effectiveness.summary.view evaluation.policy.manage evaluation.reminders.manage)
    )

    grant(94, ~w(effectiveness.view))
    grant(95, ~w(effectiveness.view effectiveness.answer))
    {:ok, scopes: scopes}
  end

  defp grant(id, caps),
    do: grant_capabilities!(Enum.map(caps, &("people.training." <> &1)), user_id: id)

  defp scope(conn, id) do
    conn
    |> log_in_as(session_user(%{"user_id" => id}))
    |> get("/people/training/courses")
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:current_scope)
    |> Map.fetch!(:scope)
  end

  defp configure(s, minimum \\ 2) do
    scope = SettingScope.company(73, 41)

    for {key, value} <- [
          {"evaluation_days", 0},
          {"checkpoints", [2, 5]},
          {"reminder_days", 0},
          {"minimum_cohort", minimum},
          {"report_grace_days", 10}
        ] do
      {:ok, _} = Settings.put("people.training.evaluation." <> key, value, scope)
    end

    s
  end

  defp criterion(code \\ "criterion"),
    do: %{"code" => code, "label" => "Outcome criterion", "minimum" => 0, "maximum" => 5}

  defp policy(s, attrs \\ %{}) do
    Training.publish_evaluation_policy(
      s[93],
      73,
      Map.merge(
        %{
          effective_from: "2026-10-01",
          effective_to: "2026-10-31",
          criteria: [criterion()],
          effectiveness_criteria: [criterion()],
          reason: "Approved evaluation policy"
        },
        attrs
      )
    )
  end

  defp session(s) do
    grant(93, ~w(courses.manage sessions.manage records.manage records.view))
    {:ok, course} = Training.create_course(s[93], 73, %{code: "course", name: "Course"})

    {:ok, event} =
      Training.create_event(s[93], 73, %{
        course_id: course.id,
        name: "Session event",
        capacity: 10
      })

    {:ok, session} =
      Training.create_session(s[93], 73, %{
        event_id: event.id,
        name: "Session",
        capacity: 10,
        time_zone: "Etc/UTC",
        starts_local: "2026-10-01T08:00",
        ends_local: "2026-10-01T09:00"
      })

    session
  end

  defp attendance(s, session, employee, status \\ "confirmed", key \\ "attendance") do
    Participation.record(s[93], 73, %{
      session_id: session.id,
      employee_id: employee,
      status: status,
      reason: "Attendance evidence",
      import_key: "#{key}-#{employee}"
    })
  end

  defp prepared(s) do
    configure(s)
    {:ok, p} = policy(s)
    session = session(s)
    {:ok, f} = attendance(s, session, 2)

    {:ok, %{reviews: reviews, unknown: 0}} =
      Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-01 09:00:00Z])

    {p, session, f, reviews}
  end

  test "policy settings fail closed, criteria are versioned and overlap refuses", %{scopes: s} do
    assert {:error, :policy_not_configured} = policy(s)

    assert {:error, :report_not_configured} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-01-11])

    configure(s)
    assert {:error, :invalid_criteria} = policy(s, %{criteria: [criterion(), criterion()]})
    assert {:ok, first} = policy(s)
    assert first.version == 1 and first.criteria == %{"items" => [criterion()]}
    assert {:error, :overlapping_policy} = policy(s)

    assert {:ok, second} =
             policy(s, %{
               effective_from: "2026-11-01",
               effective_to: "2026-11-30",
               criteria: [criterion("next")]
             })

    assert second.version == 2
    assert {:error, :unauthorized} = Training.publish_evaluation_policy(s[92], 73, %{})
  end

  test "prepare is idempotent and captures the session completion policy and local day", %{
    scopes: s
  } do
    {p, session, _, reviews} = prepared(s)
    assert length(reviews) == 3
    assert Enum.all?(reviews, &(&1.policy_id == p.id))
    assert Enum.map(reviews, & &1.due_on) == [~D[2026-10-01], ~D[2026-10-03], ~D[2026-10-06]]

    assert {:ok, %{reviews: ^reviews}} =
             Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-02 09:00:00Z])

    assert {:error, :session_not_finished} =
             Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-01 08:59:59Z])

    {:ok, _} = attendance(s, session, 2, "confirmed", "correction")

    assert {:ok, %{reviews: ^reviews}} =
             Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-02 09:00:00Z])
  end

  test "due-day reminders include due today, remain idempotent and omit answered reviews", %{
    scopes: s
  } do
    {_, _, _, [evaluation, effectiveness | _]} = prepared(s)

    assert {:ok, %{created: 0, unknown: 0}} =
             Training.evaluation_reminders(s[93], 73, ~D[2026-09-30])

    assert {:ok, %{created: 1, unknown: 0}} =
             Training.evaluation_reminders(s[93], 73, ~D[2026-10-01])

    assert {:ok, %{created: 0, unknown: 0}} =
             Training.evaluation_reminders(s[93], 73, ~D[2026-10-01])

    assert {:ok, [r]} = Training.evaluation_reviews(s[91], 73, "evaluation")
    assert r.id == evaluation.id and r.reminder.available_on == ~D[2026-10-01]

    assert {:ok, _} =
             Training.answer_evaluation(
               s[92],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "Observed outcome"
             )

    assert {:ok, %{created: 0, unknown: 0}} =
             Training.evaluation_reminders(s[93], 73, ~D[2026-10-03])
  end

  test "employee and HOD answers preserve policy and attribution; HR cannot answer", %{scopes: s} do
    {p, _, _, [evaluation, effectiveness | _]} = prepared(s)

    assert {:error, :unauthorized} =
             Training.answer_evaluation(
               s[93],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "HR attempt"
             )

    assert {:error, :outside_team} =
             Training.answer_evaluation(
               s[95],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "Other HOD"
             )

    assert {:ok, []} = Training.evaluation_reviews(s[95], 73, "effectiveness")

    assert {:error, :invalid_answers} =
             Training.answer_evaluation(s[91], 73, evaluation.id, %{"criterion" => 6}, "Too high")

    assert {:error, :invalid_answers} =
             Training.answer_evaluation(s[91], 73, evaluation.id, %{}, "Missing criterion")

    assert {:ok, answer} =
             Training.answer_evaluation(
               s[91],
               73,
               evaluation.id,
               %{"criterion" => nil},
               "Unknown outcome"
             )

    assert answer.actor_user_id == 91 and answer.values == %{"criterion" => nil}

    assert {:error, :already_answered} =
             Training.answer_evaluation(s[91], 73, evaluation.id, %{"criterion" => 4}, "Repeat")

    assert {:ok, _} =
             Training.answer_evaluation(
               s[92],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "Observed outcome"
             )

    {:ok, [r | _]} = Training.evaluation_reviews(s[92], 73, "effectiveness")
    assert r.policy_id == p.id and r.answer.actor_user_id == 92
  end

  test "one departed attendee is skipped and counted while the others get reviews", %{
    scopes: s
  } do
    configure(s)
    {:ok, _} = policy(s)
    session = session(s)
    {:ok, _} = attendance(s, session, 2)
    {:ok, _} = attendance(s, session, 3)
    {:ok, _} = Bilimbi.Core.Employee.update_employee(s[93], 73, 3, %{status: "inactive"})

    assert {:ok, %{reviews: reviews, unknown: 1}} =
             Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-01 09:00:00Z])

    assert length(reviews) == 3
    assert {:ok, [evaluation]} = Training.evaluation_reviews(s[91], 73, "evaluation")
    assert evaluation.employee_id == 2 and evaluation.id in Enum.map(reviews, & &1.id)

    assert {:ok, %{reviews: ^reviews, unknown: 1}} =
             Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-02 09:00:00Z])
  end

  defp answer!(s, review, score) do
    {:ok, _} =
      Training.answer_evaluation(s[92], 73, review.id, %{"criterion" => score}, "Observed result")
  end

  defp add_attendee(s, session, number) do
    {:ok, employee} =
      Bilimbi.Core.Employee.create_employee(s[93], 73, %{
        employee_number: "employee-#{number}",
        full_name: "Employee #{number}",
        employee_type: "employee_type",
        status: "active",
        supervisor_id: 1
      })

    {:ok, _} = attendance(s, session, employee.id)

    {:ok, _} =
      Training.prepare_evaluation_reviews(s[93], 73, session.id, ~U[2026-10-02 09:00:00Z])

    {:ok, reviews} = Training.evaluation_reviews(s[92], 73, "effectiveness")
    Enum.find(reviews, &(&1.employee_id == employee.id and &1.checkpoint_days == 2))
  end

  test "a small cohort freezes suppressed and a later answer cannot reveal it", %{scopes: s} do
    {_, session, _, [_, effectiveness | _]} = prepared(s)
    answer!(s, effectiveness, 5)

    assert {:ok, %{frozen: 1}} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-01-11])

    assert {:ok, [frozen]} = Training.effectiveness_summary(s[93], 73)

    assert %{
             status: "suppressed",
             period_start: ~D[2026-10-01],
             period_end: ~D[2026-12-31],
             groups: %{"items" => []}
           } = frozen

    answer!(s, add_attendee(s, session, 104), 1)

    assert {:ok, %{frozen: 0}} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-02-01])

    assert {:ok, [^frozen]} = Training.effectiveness_summary(s[93], 73)
  end

  test "frozen period summaries exclude unknown scores and never change after freezing", %{
    scopes: s
  } do
    {_, session, _, [_, effectiveness, later]} = prepared(s)
    answer!(s, effectiveness, 5)
    answer!(s, add_attendee(s, session, 104), nil)
    answer!(s, add_attendee(s, session, 105), 3)

    assert {:ok, %{frozen: 0}} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-01-10])

    assert {:ok, []} = Training.effectiveness_summary(s[93], 73)

    assert {:ok, %{frozen: 1}} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-01-11])

    assert {:ok, [frozen]} = Training.effectiveness_summary(s[93], 73)
    assert frozen.status == "current" and frozen.minimum_cohort == 2

    assert [
             %{
               "checkpoint_days" => 2,
               "status" => "current",
               "criteria" => [%{"status" => "current", "answered" => 2, "mean" => "4.00"}]
             },
             %{
               "checkpoint_days" => 5,
               "status" => "current",
               "criteria" => [%{"status" => "suppressed", "answered" => nil, "mean" => nil}]
             }
           ] = frozen.groups["items"]

    answer!(s, later, 0)

    assert {:ok, %{frozen: 0}} =
             Training.freeze_effectiveness_summaries(s[93], 73, ~D[2027-02-01])

    assert {:ok, [^frozen]} = Training.effectiveness_summary(s[93], 73)
    assert {:error, :unauthorized} = Training.effectiveness_summary(s[92], 73)

    assert {:error, :unauthorized} =
             Training.freeze_effectiveness_summaries(s[92], 73, ~D[2027-02-01])
  end

  test "employees answer their own evaluations under My learning without Effectiveness access",
       %{conn: conn, scopes: s} do
    {_, _, _, [evaluation | _]} = prepared(s)
    conn = log_in_as(conn, session_user(%{"user_id" => 91}))
    assert {:error, _} = live(conn, "/people/training/effectiveness")
    {:ok, view, _} = live(conn, "/people/training/my")

    assert has_element?(view, "#evaluation-#{evaluation.id}", "Awaiting answer")
    view |> element("#evaluation-#{evaluation.id} button", "Answer") |> render_click()

    view
    |> form("#my-evaluation-form",
      evaluation: %{values: %{criterion: "4"}, reason: "Applied at work"}
    )
    |> render_submit()

    view |> element("#my-evaluation-confirm-confirm") |> render_click()
    assert has_element?(view, "#evaluation-#{evaluation.id}", "Answered")
    assert {:ok, [%{answer: %{values: %{"criterion" => 4}}}]} =
             Training.evaluation_reviews(s[91], 73, "evaluation")

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        s[91],
        73,
        :user,
        91,
        "people.training.evaluation.submit",
        false
      )

    {:ok, view, _} = live(conn, "/people/training/my")
    refute has_element?(view, "#my-evaluations")

    for event <- ~w(open_evaluation save_evaluation confirm_evaluation) do
      assert render_hook(view, event, %{"id" => to_string(evaluation.id)}) =~ "cannot"
    end
  end

  test "unknown workforce, lost reporting line and attendance corrections refuse work", %{
    scopes: s
  } do
    {_, session, _, [_, effectiveness | _]} = prepared(s)
    {:ok, _} = Bilimbi.Core.Employee.update_employee(s[93], 73, 2, %{supervisor_id: nil})

    assert {:error, :outside_team} =
             Training.answer_evaluation(
               s[92],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "Lost team"
             )

    assert {:ok, %{created: 1, unknown: 1}} =
             Training.evaluation_reminders(s[93], 73, ~D[2026-10-03])

    {:ok, _} = attendance(s, session, 2, "absent", "correction")

    assert {:error, :attendance_unavailable} =
             Training.answer_evaluation(
               s[92],
               73,
               effectiveness.id,
               %{"criterion" => 5},
               "Absent"
             )

    assert {:ok, []} = Training.evaluation_reviews(s[91], 73, "evaluation")
    {:ok, _} = Bilimbi.Core.Employee.update_employee(s[93], 73, 1, %{status: "inactive"})

    assert {:error, :employee_unavailable} =
             Training.evaluation_reviews(s[92], 73, "effectiveness")
  end

  test "route, company, tenant, system and forged-event boundaries refuse", %{
    conn: conn,
    scopes: s
  } do
    assert {:error, _} = live(conn, "/people/training/effectiveness")

    assert {:error, _} =
             conn
             |> log_in_as(session_user(%{"user_id" => 94}))
             |> live("/people/training/effectiveness?company_id=74")
             |> denied_company()

    {:ok, view, _} =
      conn
      |> log_in_as(session_user(%{"user_id" => 94}))
      |> live("/people/training/effectiveness")

    assert has_element?(view, "#effectiveness-forbidden")

    for event <-
          ~w(open_answer save_answer confirm_answer open_policy save_policy confirm_policy prepare_reviews run_reminders freeze_summaries) do
      assert render_hook(view, event, %{}) =~ "cannot"
    end

    for company <- [74, 75] do
      assert {:error, :unauthorized} = Training.evaluation_policies(s[93], company)

      assert {:error, :unauthorized} = Training.effectiveness_summary(s[93], company)

      assert {:error, :unauthorized} =
               Training.answer_evaluation(s[92], company, 1, %{}, "Wrong company")
    end

    {:ok, system} = Tenancy.scope(41)
    assert {:error, :unauthorized} = Training.evaluation_policies(system, 73)
  end

  defp denied_company({:ok, view, _}) do
    assert render(view) =~ "No company is available"
    {:error, :company_unavailable}
  end

  defp denied_company(other), do: other

  test "HOD form submits through confirmation and revocation refuses an open page", %{
    conn: conn,
    scopes: s
  } do
    {_, _, _, [_, effectiveness | _]} = prepared(s)

    {:ok, view, _} =
      conn
      |> log_in_as(session_user(%{"user_id" => 92}))
      |> live("/people/training/effectiveness")

    assert has_element?(view, "#review-#{effectiveness.id}")
    view |> element("#review-#{effectiveness.id} button", "Answer") |> render_click()

    view
    |> form("#evaluation-answer-form",
      entry: %{values: %{criterion: "4"}, reason: "Observed application"}
    )
    |> render_submit()

    view |> element("#evaluation-answer-confirm-confirm") |> render_click()
    assert has_element?(view, "#review-#{effectiveness.id}", "Answered")

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        s[92],
        73,
        :user,
        92,
        "people.training.effectiveness.answer",
        false
      )

    assert {:error, :unauthorized} =
             Training.answer_evaluation(
               s[92],
               73,
               effectiveness.id,
               %{"criterion" => 4},
               "Revoked"
             )
  end

  test "fresh schema and PostgreSQL preserve immutable criteria and answers", %{scopes: s} do
    assert :ok =
             Bilimbi.Base.Database.SchemaVerifier.verify(Repo, Training.SchemaContract.tables())

    {p, _, _, [evaluation | _]} = prepared(s)

    {:ok, a} =
      Training.answer_evaluation(s[91], 73, evaluation.id, %{"criterion" => nil}, "Unknown")

    for {sql, id} <- [
          {"UPDATE people_training_evaluation_policies SET reason = 'Rewrite' WHERE id = $1",
           p.id},
          {"DELETE FROM people_training_evaluation_answers WHERE id = $1", a.id}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Ecto.Adapters.SQL.query(Repo, sql, [id], mode: :savepoint)
    end
  end

  test "operator publication form captures configured offsets and later Settings cannot rewrite reviews",
       %{conn: conn, scopes: s} do
    configure(s)

    {:ok, view, _} =
      conn
      |> log_in_as(session_user(%{"user_id" => 93}))
      |> live("/people/training/effectiveness")

    assert has_element?(view, "#evaluation-policies")
    refute has_element?(view, "#effectiveness-reviews")
    view |> element("button", "Publish criteria") |> render_click()

    view
    |> form("#evaluation-policy-form",
      entry: %{
        effective_from: "2026-10-01",
        effective_to: "2026-10-31",
        criteria: %{"1" => criterion()},
        effectiveness_criteria: %{"1" => criterion()},
        reason: "Governed criteria"
      }
    )
    |> render_submit()

    view |> element("#evaluation-policy-confirm-confirm") |> render_click()
    assert {:ok, [p]} = Training.evaluation_policies(s[93], 73)
    assert p.version == 1 and p.evaluation_days == 0 and p.checkpoints == %{"days" => [2, 5]}

    {:ok, _} =
      Settings.put("people.training.evaluation.evaluation_days", 30, SettingScope.company(73, 41))

    {:ok, _} =
      Settings.put("people.training.evaluation.checkpoints", [60], SettingScope.company(73, 41))

    session = session(s)
    {:ok, _} = attendance(s, session, 2)
    view |> form("#prepare-review-form", entry: %{session_id: session.id}) |> render_submit()
    assert {:ok, [evaluation]} = Training.evaluation_reviews(s[91], 73, "evaluation")
    assert evaluation.due_on == ~D[2026-10-01]
    assert {:ok, reviews} = Training.evaluation_reviews(s[92], 73, "effectiveness")
    assert Enum.map(reviews, & &1.checkpoint_days) == [2, 5]
    view |> element("button", "Refresh reminders") |> render_click()

    assert {:ok, [%{reminder: %{available_on: _}}]} =
             Training.evaluation_reviews(s[91], 73, "evaluation")

    assert has_element?(view, "#summary-empty")
  end

  test "session-local completion day selects the policy and inclusive due date", %{scopes: s} do
    configure(s)
    {:ok, p} = policy(s, %{effective_from: "2026-10-02", effective_to: "2026-10-02"})
    session = session(s)

    {:ok, local_session} =
      Training.create_session(s[93], 73, %{
        event_id: session.event_id,
        name: "Local session",
        capacity: 10,
        time_zone: "Pacific/Auckland",
        starts_local: "2026-10-02T00:15",
        ends_local: "2026-10-02T00:45"
      })

    assert DateTime.to_date(local_session.ends_at) == ~D[2026-10-01]
    {:ok, _} = attendance(s, local_session, 2)

    assert {:ok, %{reviews: [evaluation | _]}} =
             Training.prepare_evaluation_reviews(
               s[93],
               73,
               local_session.id,
               local_session.ends_at
             )

    assert evaluation.policy_id == p.id and evaluation.due_on == ~D[2026-10-02]
  end

  test "database refuses answer bounds and duplicate obligations across corrected facts", %{
    scopes: s
  } do
    {_, session, _, [_, review | _]} = prepared(s)
    {:ok, corrected} = attendance(s, session, 2, "confirmed", "corrected")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO people_training_evaluation_answers (tenant_id, company_id, actor_user_id, review_id, values, reason, inserted_at, updated_at) VALUES (41, 73, 92, $1, $2, 'Invalid score', now(), now())",
               [review.id, %{"criterion" => 6}], mode: :savepoint)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "INSERT INTO people_training_evaluation_reviews (tenant_id, company_id, actor_user_id, policy_id, fact_id, kind, checkpoint_days, due_on, inserted_at, updated_at) VALUES (41, 73, 93, $1, $2, 'effectiveness', 2, '2026-10-03', now(), now())",
               [review.policy_id, corrected.id], mode: :savepoint)
  end

  test "an invalid publication keeps the operator's entered criteria for correction", %{
    conn: conn,
    scopes: s
  } do
    configure(s)

    {:ok, view, _} =
      conn
      |> log_in_as(session_user(%{"user_id" => 93}))
      |> live("/people/training/effectiveness")

    view |> element("button", "Publish criteria") |> render_click()

    view
    |> form("#evaluation-policy-form",
      entry: %{
        effective_from: "2026-10-31",
        effective_to: "2026-10-01",
        criteria: %{"1" => criterion()},
        effectiveness_criteria: %{"1" => criterion()},
        reason: "Criteria under review"
      }
    )
    |> render_submit()

    view |> element("#evaluation-policy-confirm-confirm") |> render_click()

    assert has_element?(
             view,
             "#evaluation-policy-form input[name='entry[criteria][1][code]'][value='criterion']"
           )

    assert has_element?(view, "#evaluation-policy-form textarea", "Criteria under review")
    assert {:ok, []} = Training.evaluation_policies(s[93], 73)
  end

  test "one Effectiveness destination is reserved and runtime Training navigation stays hidden" do
    assert [entry] = Training.Contributions.effectiveness_menu()
    item = Bilimbi.Base.Menu.Item.new!(entry, "people/training")
    assert item.label == "Effectiveness" and item.parent == "people.development"
    assert item.route == "/people/training/effectiveness"
    assert item.capability == "people.training.effectiveness.view"
    assert Training.Contributions.contributions().menu == []
  end
end
