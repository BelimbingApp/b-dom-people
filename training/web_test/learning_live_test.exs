defmodule Bilimbi.People.Training.Web.LearningLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Repo, Tenancy}
  alias Ecto.Adapters.SQL
  alias Bilimbi.Core.Company.TestFixtures, as: Companies
  alias Bilimbi.Core.User.TestFixtures, as: Users
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.TestFixtures

  setup %{conn: conn} do
    Users.create_user_tables!()
    TestFixtures.migrate_governance_tables!()
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

  defp currencies(s), do: Training.put_learning_currencies(s[93], 73, ["AAA", "BBB"])

  defp attrs(cost \\ "40.0000"),
    do: %{
      need: "Learning need",
      objective: "Learning objective",
      expected_result: "Expected result",
      proposed_on: "2026-10-12",
      estimated_cost: cost,
      currency: "AAA"
    }

  defp allocation(s, amount \\ "100.0000") do
    {:ok, _} = currencies(s)

    Training.create_budget_policy(s[93], 73, %{
      currency: "AAA",
      effective_from: "2026-10-01",
      effective_to: "2026-10-31",
      amount: amount,
      reason: "Approved allocation"
    })
  end

  defp ready(s, cost \\ "40.0000") do
    {:ok, r} = Training.create_learning_request(s[91], 73, attrs(cost))
    {:ok, _} = Training.decide_learning_request(s[91], 73, r.id, "submit", "Learning need")

    {:ok, _} =
      Training.decide_learning_request(s[92], 73, r.id, "recommend", "Team recommendation")

    {:ok, _} = Training.decide_learning_request(s[93], 73, r.id, "review", "Reviewed need")
    r
  end

  defp plan_attrs,
    do: %{
      objectives: "Team objectives",
      period_start: "2026-10-01",
      period_end: "2026-10-31",
      reason: "Team plan"
    }

  defp items,
    do: [
      %{
        need: "Learning need",
        expected_result: "Expected result",
        target_cohort: "Team cohort",
        responsible_owner: "Accountable owner",
        intended_timing: "During plan period",
        evaluation_approach: "Observe outcome"
      }
    ]

  test "all new routes require authentication and their own capability", %{conn: conn} do
    for path <- ~w(my team plans requests plan-reviews budgets) do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/training/#{path}")

      assert {:error, _} =
               conn
               |> log_in_as(session_user(%{"user_id" => 95}))
               |> live("/people/training/#{path}")
    end
  end

  test "employee request form and decision preserve accountable history", %{conn: conn, scopes: s} do
    {:ok, _} = currencies(s)
    {:ok, live, _} = conn |> log_in_as() |> live("/people/training/my")
    assert render(live) =~ "No learning records yet"
    refute render(live) =~ "/people/training/requests?"
    live |> element("button", "Add request") |> render_click()
    live |> form("#learning-entry-form", entry: attrs()) |> render_submit()
    assert has_element?(live, "#learning-records", "Learning need")
    {:ok, [r]} = Training.learning_requests(s[91], 73, :self)

    live
    |> form("#decision-#{r.id}", decision: %{action: "submit", reason: "Request learning"})
    |> render_submit()

    live |> element("#learning-decision-confirm-confirm") |> render_click()
    assert has_element?(live, "#learning-records", "pending_hod")
    {:ok, %{r.id => history}} = Training.learning_histories(s[91], 73, :request, [r.id], :self)
    assert Enum.map(history, & &1.action) == ["create", "submit"]
    assert Enum.all?(history, &(&1.actor_user_id == 91))

    assert {:ok, %{r.id => ^history}} =
             Training.learning_histories(s[92], 73, :request, [r.id], :team)

    grant(95, ~w(requests.submit requests.recommend))
    assert {:ok, %{}} == Training.learning_histories(s[95], 73, :request, [r.id], :self)
    assert {:ok, %{}} == Training.learning_histories(s[95], 73, :request, [r.id], :team)
  end

  test "unsubmitted drafts stay private to the employee until submitted", %{scopes: s} do
    {:ok, _} = currencies(s)
    {:ok, draft} = Training.create_learning_request(s[91], 73, attrs())
    {:ok, withdrawn} = Training.create_learning_request(s[91], 73, attrs())
    {:ok, _} = Training.decide_learning_request(s[91], 73, withdrawn.id, "cancel", "Withdrawn")
    ids = [draft.id, withdrawn.id]

    assert {:ok, [_, _]} = Training.learning_requests(s[91], 73, :self)
    assert {:ok, %{}} != Training.learning_histories(s[91], 73, :request, ids, :self)

    for {actor, audience} <- [{92, :team}, {93, :hr}] do
      assert {:ok, []} = Training.learning_requests(s[actor], 73, audience)
      assert {:ok, %{}} == Training.learning_histories(s[actor], 73, :request, ids, audience)
    end

    {:ok, _} = Training.decide_learning_request(s[91], 73, draft.id, "submit", "Learning need")

    for {actor, audience} <- [{92, :team}, {93, :hr}] do
      assert {:ok, [%{id: id, status: "pending_hod"}]} =
               Training.learning_requests(s[actor], 73, audience)

      assert id == draft.id

      {:ok, histories} = Training.learning_histories(s[actor], 73, :request, ids, audience)
      assert Map.keys(histories) == [draft.id]
      assert Enum.map(histories[draft.id], & &1.action) == ["create", "submit"]
    end
  end

  test "budget viewer cannot forge allocation or currency writes", %{conn: conn, scopes: s} do
    grant(95, ~w(budgets.view))

    {:ok, live, _} =
      conn |> log_in_as(session_user(%{"user_id" => 95})) |> live("/people/training/budgets")

    refute has_element?(live, "#learning-currencies")

    for event <- ~w(open_entry save_entry save_currencies add_item decide confirm_decision),
        do: assert(render_hook(live, event, %{}) =~ "cannot change")

    assert {:error, :unauthorized} = Training.put_learning_currencies(s[95], 73, ["AAA"])
    assert {:ok, []} = Training.learning_budgets(s[93], 73)
  end

  test "fresh financial policy refuses unconfigured currencies, overlaps and precision loss", %{
    scopes: s
  } do
    assert {:error, :currency_unavailable} = Training.create_learning_request(s[91], 73, attrs())
    {:ok, _} = allocation(s)

    assert {:error, :overlapping_policy} =
             Training.create_budget_policy(s[93], 73, %{
               currency: "AAA",
               effective_from: "2026-10-15",
               effective_to: "2026-11-01",
               amount: "10",
               reason: "Overlap"
             })

    assert {:error, %Ecto.Changeset{}} =
             Training.create_learning_request(s[91], 73, attrs("0.00001"))

    assert {:error, :invalid_period} =
             Training.create_budget_policy(s[93], 73, %{
               currency: "AAA",
               effective_from: "2026-11-10",
               effective_to: "2026-11-01",
               amount: "10",
               reason: "Invalid dates"
             })

    assert {:ok, [_]} = Training.learning_budgets(s[93], 73)
  end

  test "budget correction supersedes a mistyped allocation and keeps both rows", %{
    conn: conn,
    scopes: s
  } do
    {:ok, typo} = allocation(s, "10.0000")
    r = ready(s)

    assert {:error, :budget_exceeded} =
             Training.decide_learning_request(s[94], 73, r.id, "approve", "Over typo")

    correction = %{
      effective_from: "2026-10-01",
      effective_to: "2026-10-31",
      amount: "1000.0000",
      reason: "Allocation typo"
    }

    assert {:error, %Ecto.Changeset{}} =
             Training.supersede_budget_policy(s[93], 73, typo.id, %{correction | reason: " "})

    assert {:error, :unauthorized} =
             Training.supersede_budget_policy(s[95], 73, typo.id, correction)

    assert {:ok, fixed} = Training.supersede_budget_policy(s[93], 73, typo.id, correction)
    assert fixed.supersedes_id == typo.id and fixed.currency == "AAA"

    assert {:error, :superseded_budget} =
             Training.supersede_budget_policy(s[93], 73, typo.id, correction)

    assert {:ok, approved} = Training.decide_learning_request(s[94], 73, r.id, "approve", "Fits")
    assert approved.budget_policy_id == fixed.id

    assert {:ok, [current, original]} = Training.learning_budgets(s[93], 73)
    assert {current.id, current.superseded_by} == {fixed.id, nil}
    assert {original.id, original.superseded_by} == {typo.id, fixed.id}
    assert Decimal.equal?(original.amount, "10") and original.reason == "Approved allocation"

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE people_training_budget_policies SET amount = 999 WHERE id = $1",
               [typo.id],
               mode: :savepoint
             )

    {:ok, live, _} =
      conn |> log_in_as(session_user(%{"user_id" => 93})) |> live("/people/training/budgets")

    assert has_element?(live, "#learning-#{typo.id}", "Superseded by policy #{fixed.id}")
    assert has_element?(live, "#learning-#{fixed.id}", "Corrects policy #{typo.id}")
    refute has_element?(live, "#learning-#{typo.id} button", "Correct")

    live |> element("#learning-#{fixed.id} button", "Correct") |> render_click()

    live
    |> form("#learning-entry-form",
      entry: %{correction | amount: "500.0000", reason: "Reduced allocation"}
    )
    |> render_submit()

    assert {:ok, [latest | _]} = Training.learning_budgets(s[93], 73)
    assert latest.supersedes_id == fixed.id and Decimal.equal?(latest.amount, "500")
  end

  test "budget correction refuses allocations below approved commitments", %{scopes: s} do
    {:ok, policy} = allocation(s)
    r = ready(s)
    {:ok, _} = Training.decide_learning_request(s[94], 73, r.id, "approve", "Approval")

    below = %{
      effective_from: "2026-10-01",
      effective_to: "2026-10-31",
      amount: "39.9999",
      reason: "Too small"
    }

    assert {:error, :budget_below_commitments} =
             Training.supersede_budget_policy(s[93], 73, policy.id, below)

    assert {:error, :commitments_outside_period} =
             Training.supersede_budget_policy(s[93], 73, policy.id, %{
               below
               | effective_from: "2026-10-13",
                 amount: "100"
             })

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO people_training_budget_policies (tenant_id, company_id, actor_user_id, currency, effective_from, effective_to, amount, reason, supersedes_id, inserted_at, updated_at) VALUES (41, 73, 93, 'AAA', '2026-10-01', '2026-10-31', 1, 'Bypass', $1, now(), now())",
               [policy.id],
               mode: :savepoint
             )

    assert {:ok, [only]} = Training.learning_budgets(s[93], 73)
    assert only.id == policy.id and is_nil(only.superseded_by)

    {:ok, same} =
      Training.supersede_budget_policy(s[93], 73, policy.id, %{below | amount: "100"})

    narrowed = %{below | effective_from: "2026-10-13", amount: "100"}

    assert {:error, :commitments_outside_period} =
             Training.supersede_budget_policy(s[93], 73, same.id, narrowed)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO people_training_budget_policies (tenant_id, company_id, actor_user_id, currency, effective_from, effective_to, amount, reason, supersedes_id, inserted_at, updated_at) VALUES (41, 73, 93, 'AAA', '2026-10-13', '2026-10-31', 100, 'Bypass', $1, now(), now())",
               [same.id],
               mode: :savepoint
             )
  end

  test "HR HOD employee company and system refusal precede writes", %{scopes: s} do
    {:ok, _} = allocation(s)

    {:ok, r} =
      Training.create_learning_request(
        s[91],
        73,
        Map.merge(attrs(), %{
          employee_id: 3,
          actor_user_id: 94,
          status: "approved",
          budget_policy_id: 1
        })
      )

    assert r.employee_id == 2 and r.actor_user_id == 91 and r.status == "draft"

    assert {:error, :unauthorized} =
             Training.decide_learning_request(s[91], 73, r.id, "approve", "Forged")

    assert {:error, :invalid_transition} =
             Training.decide_learning_request(s[93], 73, r.id, "review", "Too early")

    grant(95, ~w(requests.recommend))
    {:ok, _} = Training.decide_learning_request(s[91], 73, r.id, "submit", "Submit")

    assert {:error, :outside_team} =
             Training.decide_learning_request(s[95], 73, r.id, "recommend", "Wrong team")

    assert {:error, :unauthorized} =
             Training.create_learning_plan(s[91], 73, plan_attrs(), items())

    for company <- [74, 75] do
      assert {:error, :unauthorized} = Training.create_learning_request(s[91], company, attrs())
      assert {:error, :unauthorized} = Training.learning_requests(s[93], company, :hr)

      assert {:error, :unauthorized} =
               Training.create_learning_plan(s[92], company, plan_attrs(), items())

      assert {:error, :unauthorized} = Training.create_budget_policy(s[93], company, %{})
    end

    {:ok, system} = Tenancy.scope(41)
    assert {:error, :unauthorized} = Training.create_learning_request(system, 73, attrs())

    assert {:error, :not_found} =
             Training.decide_learning_request(s[91], 73, nil, "submit", "Invalid ID")
  end

  test "approval snapshots exact decimal cost and cannot overspend or repeat", %{scopes: s} do
    {:ok, policy} = allocation(s, "80.0000")
    r1 = ready(s)
    r2 = ready(s)
    r3 = ready(s, "0.0001")

    assert {:ok, approved} =
             Training.decide_learning_request(s[94], 73, r1.id, "approve", "Approve")

    assert approved.budget_policy_id == policy.id
    assert Decimal.equal?(approved.approved_cost, "40")
    assert {:ok, _} = Training.decide_learning_request(s[94], 73, r2.id, "approve", "At limit")

    assert {:error, :budget_exceeded} =
             Training.decide_learning_request(s[94], 73, r3.id, "approve", "Over limit")

    assert {:error, :invalid_transition} =
             Training.decide_learning_request(s[94], 73, r1.id, "approve", "Repeat")

    assert {:ok, [budget]} = Training.learning_budgets(s[93], 73)
    assert Decimal.equal?(budget.remaining, "0")
    assert {:ok, []} = Training.put_learning_currencies(s[93], 73, [])

    assert {:error, :currency_unavailable} =
             Training.decide_learning_request(s[94], 73, r3.id, "approve", "Disabled currency")

    {:ok, %{r1.id => history}} = Training.learning_histories(s[93], 73, :request, [r1.id], :hr)
    assert Enum.map(history, & &1.actor_user_id) == [91, 91, 92, 93, 94]
  end

  test "approval needs effective policy and independent actor; rejection and cancellation stay terminal",
       %{scopes: s} do
    {:ok, _} = currencies(s)
    r = ready(s)

    assert {:error, :budget_unavailable} =
             Training.decide_learning_request(s[94], 73, r.id, "approve", "No policy")

    grant(91, ~w(requests.approve))

    assert {:error, :self_approval} =
             Training.decide_learning_request(s[91], 73, r.id, "approve", "Own request")

    assert {:error, :reason_required} =
             Training.decide_learning_request(s[94], 73, r.id, "reject", " ")

    assert {:ok, %{status: "rejected"}} =
             Training.decide_learning_request(s[94], 73, r.id, "reject", "Need clarification")

    assert {:error, :invalid_transition} =
             Training.decide_learning_request(s[91], 73, r.id, "cancel", "Already rejected")
  end

  test "plan items, independent approval and amendments preserve prior scope", %{scopes: s} do
    assert {:error, :items_required} = Training.create_learning_plan(s[92], 73, plan_attrs(), [])

    {:ok, plan} =
      Training.create_learning_plan(s[92], 73, Map.put(plan_attrs(), :actor_user_id, 93), items())

    assert plan.actor_user_id == 92 and plan.version == 1
    {:ok, _} = Training.decide_learning_plan(s[92], 73, plan.id, "submit", "Team plan")
    grant(92, ~w(plans.approve))

    assert {:error, :self_approval} =
             Training.decide_learning_plan(s[92], 73, plan.id, "approve", "Own plan")

    assert {:ok, _} =
             Training.decide_learning_plan(s[93], 73, plan.id, "approve", "Approved scope")

    {:ok, amended} =
      Training.amend_learning_plan(
        s[92],
        73,
        plan.id,
        %{plan_attrs() | objectives: "Revised objectives", reason: "Changed needs"},
        items()
      )

    assert amended.prior_plan_id == plan.id and amended.version == 2

    assert {:ok, [%{status: "draft"}, %{status: "approved"}]} =
             Training.learning_plans(s[92], 73, :team)

    {:ok, _} = Training.decide_learning_plan(s[92], 73, amended.id, "submit", "Revised scope")

    assert {:ok, _} =
             Training.decide_learning_plan(s[93], 73, amended.id, "approve", "Approved amendment")

    assert {:ok, [%{status: "approved"}, %{status: "superseded", objectives: "Team objectives"}]} =
             Training.learning_plans(s[93], 73, :hr)

    assert {:error, :invalid_transition} =
             Training.amend_learning_plan(s[92], 73, plan.id, plan_attrs(), items())
  end

  test "unsubmitted plans and amendments stay private to the manager", %{scopes: s} do
    {:ok, plan} = Training.create_learning_plan(s[92], 73, plan_attrs(), items())
    {:ok, withdrawn} = Training.create_learning_plan(s[92], 73, plan_attrs(), items())
    {:ok, _} = Training.decide_learning_plan(s[92], 73, withdrawn.id, "cancel", "Withdrawn")
    assert {:ok, [_, _]} = Training.learning_plans(s[92], 73, :team)
    assert {:ok, []} = Training.learning_plans(s[93], 73, :hr)

    assert {:ok, %{}} ==
             Training.learning_histories(s[93], 73, :plan, [plan.id, withdrawn.id], :hr)

    {:ok, _} = Training.decide_learning_plan(s[92], 73, plan.id, "submit", "Team plan")
    {:ok, _} = Training.decide_learning_plan(s[93], 73, plan.id, "approve", "Approved scope")

    {:ok, amended} =
      Training.amend_learning_plan(
        s[92],
        73,
        plan.id,
        %{plan_attrs() | reason: "Changed"},
        items()
      )

    ids = [plan.id, withdrawn.id, amended.id]
    assert {:ok, [%{id: id}]} = Training.learning_plans(s[93], 73, :hr)
    assert id == plan.id
    {:ok, histories} = Training.learning_histories(s[93], 73, :plan, ids, :hr)
    assert Map.keys(histories) == [plan.id]

    {:ok, _} = Training.decide_learning_plan(s[92], 73, amended.id, "submit", "Revised scope")
    assert {:ok, [newest, prior]} = Training.learning_plans(s[93], 73, :hr)
    assert {newest.id, prior.id} == {amended.id, plan.id}
    {:ok, histories} = Training.learning_histories(s[93], 73, :plan, ids, :hr)
    assert Enum.map(histories[amended.id], & &1.action) == ["amend", "submit"]
    refute Map.has_key?(histories, withdrawn.id)
  end

  test "lost workforce link and revoked grants refuse an open write", %{conn: conn, scopes: s} do
    {:ok, _} = currencies(s)
    {:ok, live, _} = conn |> log_in_as() |> live("/people/training/my")

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        s[91],
        73,
        :user,
        91,
        "people.training.requests.submit",
        false
      )

    assert render_hook(live, "save_entry", %{"entry" => attrs()}) =~ "cannot do that"
    grant(91, ~w(requests.submit))
    {:ok, _} = Bilimbi.Core.Employee.update_employee(s[91], 73, 2, %{status: "inactive"})
    assert {:error, :employee_unavailable} = Training.create_learning_request(s[91], 73, attrs())
  end

  test "fresh contract and PostgreSQL protect decision facts and effective allocations", %{
    scopes: s
  } do
    assert :ok =
             Bilimbi.Base.Database.SchemaVerifier.verify(Repo, Training.SchemaContract.tables())

    {:ok, policy} = allocation(s)
    r = ready(s)
    {:ok, _} = Training.decide_learning_request(s[94], 73, r.id, "approve", "Approval")

    for {sql, args} <- [
          {"UPDATE people_training_requests SET need = 'Rewrite' WHERE id = $1", [r.id]},
          {"UPDATE people_training_budget_policies SET amount = 999 WHERE id = $1", [policy.id]},
          {"DELETE FROM people_training_request_decisions WHERE request_id = $1", [r.id]},
          {"UPDATE people_training_requests SET status = 'draft' WHERE id = $1", [r.id]}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(Repo, sql, args, mode: :savepoint)
    end

    assert {:ok, [approved]} = Training.learning_requests(s[91], 73, :self)
    assert approved.need == "Learning need" and approved.status == "approved"
  end
end
