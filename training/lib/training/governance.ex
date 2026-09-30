defmodule Bilimbi.People.Training.Governance do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.User
  alias Bilimbi.People.{Training, Workforce}
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Training.{
    BudgetPolicy,
    Request,
    RequestDecision,
    Plan,
    PlanItem,
    PlanDecision
  }

  @currencies "people.training.currencies"
  @request_steps %{
    "submit" => {"draft", "pending_hod", "requests.submit"},
    "recommend" => {"pending_hod", "pending_hr", "requests.recommend"},
    "review" => {"pending_hr", "pending_approval", "requests.review"},
    "approve" => {"pending_approval", "approved", "requests.approve"}
  }
  def currencies(%Scope{} = scope, company_id) do
    with :ok <- auth(scope, company_id, "budgets.view"),
         do: {:ok, currency_values(scope, company_id)}
  end

  def put_currencies(%Scope{} = scope, company_id, values) do
    with :ok <- auth(scope, company_id, "budgets.manage"),
         true <-
           is_list(values) and
             Enum.all?(values, &(is_binary(&1) and Regex.match?(~r/^[A-Z]{3}$/, &1))) do
      Settings.put(
        @currencies,
        Enum.uniq(values),
        SettingsScope.company(company_id, Scope.tenant_id(scope))
      )
    else
      false -> {:error, :invalid_currencies}
      error -> error
    end
  end

  def create_budget(%Scope{} = scope, company_id, attrs),
    do: put_budget(scope, company_id, nil, attrs)

  def supersede_budget(%Scope{} = scope, company_id, id, attrs),
    do: put_budget(scope, company_id, id, attrs)

  defp put_budget(scope, company_id, prior_id, attrs) do
    with :ok <- auth(scope, company_id, "budgets.manage") do
      tx(scope, company_id, fn ->
        attrs =
          stringify(attrs) |> Map.take(~w(currency effective_from effective_to amount reason))

        attrs =
          if prior_id do
            prior = fetch!(BudgetPolicy, scope, company_id, prior_id)

            require!(
              Repo.exists?(
                from(p in active_budgets(scope, company_id), where: p.id == ^prior.id)
              ),
              :superseded_budget
            )

            Map.merge(attrs, %{"currency" => prior.currency, "supersedes_id" => prior.id})
          else
            attrs
          end

        row = prepare!(BudgetPolicy, scope, company_id, attrs)
        currency!(scope, company_id, row.currency)
        require!(Date.compare(row.effective_to, row.effective_from) != :lt, :invalid_period)

        overlap =
          Repo.exists?(
            from(p in active_budgets(scope, company_id),
              where:
                p.currency == ^row.currency and p.effective_from <= ^row.effective_to and
                  p.effective_to >= ^row.effective_from and p.id != ^(prior_id || 0)
            )
          )

        require!(not overlap, :overlapping_policy)

        if prior_id do
          require!(
            not Repo.exists?(
              from(r in scoped(Request, scope, company_id),
                where:
                  r.budget_policy_id == ^prior_id and
                    (r.proposed_on < ^row.effective_from or r.proposed_on > ^row.effective_to)
              )
            ),
            :commitments_outside_period
          )
        end

        require!(
          Decimal.compare(spent(scope, company_id, row), row.amount) != :gt,
          :budget_below_commitments
        )

        view(insert!(BudgetPolicy, scope, company_id, attrs))
      end)
    end
  end

  def budgets(%Scope{} = scope, company_id) do
    with :ok <- auth(scope, company_id, "budgets.view") do
      rows =
        Repo.all(
          from(p in scoped(BudgetPolicy, scope, company_id),
            order_by: [desc: p.effective_from, desc: p.id]
          )
        )

      successors = Map.new(rows, &{&1.supersedes_id, &1.id})

      {:ok,
       Enum.map(rows, fn p ->
         spent = spent(scope, company_id, p)

         view(p)
         |> Map.merge(%{
           superseded_by: successors[p.id],
           committed: spent,
           remaining: Decimal.sub(p.amount, spent)
         })
       end)}
    end
  end

  def create_request(%Scope{} = scope, company_id, attrs) do
    with :ok <- auth(scope, company_id, "requests.submit"),
         {:ok, employee_id} <- self_employee(scope, company_id) do
      tx(scope, company_id, fn ->
        attrs =
          attrs
          |> stringify()
          |> Map.take(
            ~w(course_id need objective expected_result proposed_on estimated_cost currency)
          )
          |> Map.merge(%{"employee_id" => employee_id, "status" => "draft"})

        row = insert!(Request, scope, company_id, attrs)
        currency!(scope, company_id, row.currency)

        if row.course_id do
          course = fetch!(Bilimbi.People.Training.Course, scope, company_id, row.course_id)
          require!(course.active, :course_unavailable)
        end

        decision!(RequestDecision, :request_id, row, scope, "create", "new", "draft", "Created")
        view(row)
      end)
    end
  end

  def requests(%Scope{} = scope, company_id, audience) when audience in [:self, :team, :hr] do
    cap = %{self: "requests.submit", team: "requests.recommend", hr: "requests.view"}[audience]

    with :ok <- auth(scope, company_id, cap),
         {:ok, ids} <- audience_ids(scope, company_id, audience) do
      query = scoped(Request, scope, company_id)
      query = if ids == :company, do: query, else: from(r in query, where: r.employee_id in ^ids)
      {:ok, Repo.all(from(r in query, order_by: [desc: r.id])) |> Enum.map(&view/1)}
    end
  end

  def decide_request(%Scope{} = scope, company_id, id, action, reason) do
    # Resolve the state under the same company lock as its budget reservation.
    with :ok <-
           any_auth(
             scope,
             company_id,
             ~w(requests.submit requests.recommend requests.review requests.approve)
           ) do
      tx(scope, company_id, fn ->
        row = fetch!(Request, scope, company_id, id)

        require!(
          is_binary(reason) and String.trim(reason) != "" and byte_size(reason) <= 4000,
          :reason_required
        )

        {from, to, cap} = request_step!(row.status, action)
        require_auth!(scope, company_id, cap)
        require!(row.status == from, :invalid_transition)
        current_employee!(scope, company_id, row.employee_id)

        case cap do
          "requests.submit" ->
            require!({:ok, row.employee_id} == self_employee(scope, company_id), :not_owner)

          "requests.recommend" ->
            require!(team_member?(scope, company_id, row.employee_id), :outside_team)

          _ ->
            independent!(scope, company_id, row)
        end

        changes =
          if to == "approved" do
            currency!(scope, company_id, row.currency)

            policy =
              Repo.one(
                from(p in active_budgets(scope, company_id),
                  where:
                    p.currency == ^row.currency and p.effective_from <= ^row.proposed_on and
                      p.effective_to >= ^row.proposed_on
                )
              )

            require!(policy != nil, :budget_unavailable)

            require!(
              Decimal.compare(
                Decimal.add(spent(scope, company_id, policy), row.estimated_cost),
                policy.amount
              ) != :gt,
              :budget_exceeded
            )

            [status: to, budget_policy_id: policy.id, approved_cost: row.estimated_cost]
          else
            [status: to]
          end

        updated = row |> Ecto.Changeset.change(changes) |> Repo.update!()
        decision!(RequestDecision, :request_id, row, scope, action, from, to, reason)
        view(updated)
      end)
    end
  end

  defp request_step!(status, "reject") do
    cap =
      %{
        "pending_hod" => "requests.recommend",
        "pending_hr" => "requests.review",
        "pending_approval" => "requests.approve"
      }[status]

    require!(cap != nil, :invalid_transition)
    {status, "rejected", cap}
  end

  defp request_step!(status, "cancel") do
    require!(status in ~w(draft pending_hod pending_hr pending_approval), :invalid_transition)
    {status, "cancelled", "requests.submit"}
  end

  defp request_step!(_status, action) do
    require!(Map.has_key?(@request_steps, action), :invalid_transition)
    @request_steps[action]
  end

  def create_plan(%Scope{} = scope, company_id, attrs, items) do
    with :ok <- auth(scope, company_id, "plans.submit"),
         {:ok, manager_id} <- self_employee(scope, company_id) do
      tx(scope, company_id, fn ->
        require!(has_team?(scope, company_id, manager_id), :outside_team)

        attrs =
          stringify(attrs)
          |> Map.take(~w(period_start period_end objectives reason))
          |> Map.merge(%{
            "manager_employee_id" => manager_id,
            "version" => 1,
            "plan_key" => Ecto.UUID.generate(),
            "status" => "draft"
          })

        row = insert!(Plan, scope, company_id, attrs)
        write_items!(scope, company_id, row, items)
        decision!(PlanDecision, :plan_id, row, scope, "create", "new", "draft", row.reason)
        plan_view(scope, company_id, row)
      end)
    end
  end

  def amend_plan(%Scope{} = scope, company_id, id, attrs, items) do
    with :ok <- auth(scope, company_id, "plans.submit") do
      tx(scope, company_id, fn ->
        prior = fetch!(Plan, scope, company_id, id)
        owner!(scope, company_id, prior)
        require!(prior.status == "approved", :invalid_transition)

        version =
          Repo.one(
            from(p in scoped(Plan, scope, company_id),
              where: p.plan_key == ^prior.plan_key,
              select: max(p.version)
            )
          ) + 1

        attrs =
          stringify(attrs)
          |> Map.take(~w(period_start period_end objectives reason))
          |> Map.merge(%{
            "manager_employee_id" => prior.manager_employee_id,
            "version" => version,
            "plan_key" => prior.plan_key,
            "status" => "draft",
            "prior_plan_id" => prior.id
          })

        row = insert!(Plan, scope, company_id, attrs)
        write_items!(scope, company_id, row, items)
        decision!(PlanDecision, :plan_id, row, scope, "amend", "new", "draft", row.reason)
        plan_view(scope, company_id, row)
      end)
    end
  end

  def plans(%Scope{} = scope, company_id, audience) when audience in [:team, :hr] do
    cap = if audience == :hr, do: "plans.view", else: "plans.submit"

    with :ok <- auth(scope, company_id, cap) do
      query = scoped(Plan, scope, company_id)

      if audience == :hr do
        {:ok,
         Repo.all(from(p in query, order_by: [desc: p.id]))
         |> Enum.map(&plan_view(scope, company_id, &1))}
      else
        with {:ok, id} <- self_employee(scope, company_id) do
          {:ok,
           Repo.all(from(p in query, where: p.manager_employee_id == ^id, order_by: [desc: p.id]))
           |> Enum.map(&plan_view(scope, company_id, &1))}
        end
      end
    end
  end

  def decide_plan(%Scope{} = scope, company_id, id, action, reason) do
    cap = if action in ~w(submit cancel), do: "plans.submit", else: "plans.approve"

    with :ok <- auth(scope, company_id, cap) do
      tx(scope, company_id, fn ->
        row = fetch!(Plan, scope, company_id, id)

        require!(
          is_binary(reason) and String.trim(reason) != "" and byte_size(reason) <= 4000,
          :reason_required
        )

        {from, to} =
          case action do
            "submit" -> {"draft", "submitted"}
            "approve" -> {"submitted", "approved"}
            "reject" -> {"submitted", "rejected"}
            "cancel" -> {"draft", "cancelled"}
            _ -> Repo.rollback(:invalid_transition)
          end

        require!(row.status == from, :invalid_transition)

        if cap == "plans.submit",
          do: owner!(scope, company_id, row),
          else: independent!(scope, company_id, row)

        current_employee!(scope, company_id, row.manager_employee_id)

        if to == "approved" and row.prior_plan_id do
          prior = fetch!(Plan, scope, company_id, row.prior_plan_id)
          require!(prior.status == "approved", :superseded_plan)
          prior |> Ecto.Changeset.change(status: "superseded") |> Repo.update!()

          decision!(
            PlanDecision,
            :plan_id,
            prior,
            scope,
            "supersede",
            "approved",
            "superseded",
            reason
          )
        end

        updated = row |> Ecto.Changeset.change(status: to) |> Repo.update!()
        decision!(PlanDecision, :plan_id, row, scope, action, from, to, reason)
        plan_view(scope, company_id, updated)
      end)
    end
  end

  def history(%Scope{} = scope, company_id, kind, id, audience) when kind in [:request, :plan] do
    {schema, decisions, key, cap} =
      case {kind, audience} do
        {:request, :self} -> {Request, RequestDecision, :request_id, "requests.submit"}
        {:request, :team} -> {Request, RequestDecision, :request_id, "requests.recommend"}
        {:request, :hr} -> {Request, RequestDecision, :request_id, "requests.view"}
        {:plan, :team} -> {Plan, PlanDecision, :plan_id, "plans.submit"}
        {:plan, :hr} -> {Plan, PlanDecision, :plan_id, "plans.view"}
      end

    with :ok <- auth(scope, company_id, cap),
         true <- is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
         row when not is_nil(row) <-
           Repo.one(from(r in scoped(schema, scope, company_id), where: r.id == ^id)),
         true <- visible_history?(scope, company_id, kind, row, audience) do
      {:ok,
       Repo.all(
         from(d in scoped(decisions, scope, company_id),
           where: field(d, ^key) == ^id,
           order_by: [asc: d.id]
         )
       )
       |> Enum.map(&view/1)}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp visible_history?(_, _, _, _, :hr), do: true

  defp visible_history?(scope, company_id, :request, row, :self),
    do: self_employee(scope, company_id) == {:ok, row.employee_id}

  defp visible_history?(scope, company_id, :request, row, :team),
    do: team_member?(scope, company_id, row.employee_id)

  defp visible_history?(scope, company_id, :plan, row, :team),
    do: self_employee(scope, company_id) == {:ok, row.manager_employee_id}

  defp write_items!(scope, company_id, row, items) do
    require!(Date.compare(row.period_end, row.period_start) != :lt, :invalid_period)
    require!(is_list(items) and length(items) in 1..300, :items_required)

    for attrs <- items do
      item = insert!(PlanItem, scope, company_id, Map.put(stringify(attrs), "plan_id", row.id))

      if item.request_id do
        request = fetch!(Request, scope, company_id, item.request_id)
        require!(team_member?(scope, company_id, request.employee_id), :outside_team)
        require!(request.status == "approved", :request_unapproved)
      end
    end
  end

  defp owner!(scope, company_id, row) do
    require!(
      Scope.actor(scope).user_id == row.actor_user_id and
        {:ok, row.manager_employee_id} == self_employee(scope, company_id),
      :not_owner
    )

    require!(has_team?(scope, company_id, row.manager_employee_id), :outside_team)
  end

  defp independent!(scope, company_id, row) do
    require!(row.actor_user_id != Scope.actor(scope).user_id, :self_approval)
    subject = Map.get(row, :employee_id) || Map.get(row, :manager_employee_id)
    require!(self_employee(scope, company_id) != {:ok, subject}, :self_approval)
  end

  defp audience_ids(_scope, _company_id, :hr), do: {:ok, :company}

  defp audience_ids(scope, company_id, :self) do
    with {:ok, id} <- self_employee(scope, company_id), do: {:ok, [id]}
  end

  defp audience_ids(scope, company_id, :team) do
    with {:ok, id} <- self_employee(scope, company_id),
         {:ok, read} <- Workforce.employees(scope, company_id),
         {:ok, employees} <- ReadResult.require_current(read) do
      {:ok,
       for(
         e <- employees,
         e.supervisor_reference && e.supervisor_reference.stable_id == to_string(id),
         do: String.to_integer(e.reference.stable_id)
       )}
    end
  end

  defp team_member?(scope, company_id, employee_id) do
    case audience_ids(scope, company_id, :team) do
      {:ok, ids} -> employee_id in ids
      _ -> false
    end
  end

  defp has_team?(scope, company_id, _id) do
    case audience_ids(scope, company_id, :team) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp self_employee(scope, company_id) do
    actor = Scope.actor(scope)

    with true <- actor.company_id == company_id,
         {:ok, user} <- User.get_user(scope, company_id, actor.user_id),
         id when is_integer(id) <- user.employee_id,
         {:ok, read} <- Workforce.employee(scope, company_id, id),
         {:ok, _} <- ReadResult.require_current(read) do
      {:ok, id}
    else
      _ -> {:error, :employee_unavailable}
    end
  end

  defp current_employee!(scope, company_id, id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, id),
         {:ok, _} <- ReadResult.require_current(read) do
      :ok
    else
      _ -> Repo.rollback(:employee_unavailable)
    end
  end

  defp active_budgets(scope, company_id),
    do:
      from(p in scoped(BudgetPolicy, scope, company_id),
        where:
          p.id not in subquery(
            from(s in BudgetPolicy,
              where: not is_nil(s.supersedes_id),
              select: s.supersedes_id
            )
          )
      )

  defp spent(scope, company_id, p) do
    Repo.one(
      from(r in scoped(Request, scope, company_id),
        where:
          r.status == "approved" and r.currency == ^p.currency and
            r.proposed_on >= ^p.effective_from and r.proposed_on <= ^p.effective_to,
        select: sum(r.approved_cost)
      )
    ) || Decimal.new(0)
  end

  defp plan_view(scope, company_id, row),
    do:
      Map.put(
        view(row),
        :items,
        Repo.all(
          from(i in scoped(PlanItem, scope, company_id),
            where: i.plan_id == ^row.id,
            order_by: i.id
          )
        )
        |> Enum.map(&view/1)
      )

  defp decision!(schema, key, row, scope, action, from, to, reason),
    do:
      insert!(schema, scope, row.company_id, %{
        key => row.id,
        :action => action,
        :from_status => from,
        :to_status => to,
        :reason => reason
      })

  defp prepare!(schema, scope, company_id, attrs) do
    row =
      struct(schema,
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        actor_user_id: Scope.actor(scope).user_id,
        impersonator_id: Scope.actor(scope).impersonator_id
      )

    changeset = schema.changeset(row, attrs)
    require!(changeset.valid?, changeset)
    Ecto.Changeset.apply_changes(changeset)
  end

  defp insert!(schema, scope, company_id, attrs) do
    row =
      struct(schema,
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        actor_user_id: Scope.actor(scope).user_id,
        impersonator_id: Scope.actor(scope).impersonator_id
      )

    case row |> schema.changeset(attrs) |> Repo.insert() do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp scoped(schema, scope, company_id),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company_id)

  defp fetch!(schema, scope, company_id, id) do
    require!(is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807, :not_found)

    Repo.one(from(r in scoped(schema, scope, company_id), where: r.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp currency_values(scope, company_id),
    do: Settings.get(@currencies, SettingsScope.company(company_id, Scope.tenant_id(scope)))

  defp currency!(scope, company_id, value),
    do: require!(value in currency_values(scope, company_id), :currency_unavailable)

  defp auth(scope, company_id, suffix),
    do:
      if(Training.allowed?(scope, company_id, "people.training." <> suffix),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp any_auth(scope, company_id, suffixes),
    do:
      if(Enum.any?(suffixes, &(auth(scope, company_id, &1) == :ok)),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp require_auth!(scope, company_id, suffix),
    do: require!(auth(scope, company_id, suffix) == :ok, :unauthorized)

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)

  defp tx(scope, company_id, fun) do
    Repo.transaction(fn ->
      # All policy and commitment mutations for one company serialize, including
      # first allocations. No absent-row race can approve past the allocation.
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "people.training:#{Scope.tenant_id(scope)}:#{company_id}"
      ])

      fun.()
    end)
  end

  defp view(row), do: row |> Map.from_struct() |> Map.drop([:__meta__])
  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
