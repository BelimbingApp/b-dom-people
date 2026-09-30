defmodule Bilimbi.People.Skills.Actions do
  @moduledoc false
  # Development actions and the company's action types. An action is proposed
  # from a current assessment gap, or manually with a recorded reason, and keeps
  # a snapshot of that gap. Approval is independent of the proposer. The owner
  # or a manager then moves it through its lifecycle, and a finalized
  # reassessment after the intervention closes it. Every change is an event.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope

  alias Bilimbi.People.Skills.{
    Access,
    Action,
    ActionEvent,
    ActionType,
    Assessment,
    Assessments,
    Policy,
    Score,
    Skill
  }

  @view "people.skills.actions.view"
  @update "people.skills.actions.update"
  @manage "people.skills.actions.manage"
  @approve "people.skills.actions.approve"
  @limit 300
  @open ~w(not_started scheduled in_progress on_hold)
  @criticalities ~w(critical essential development)

  ## Action types

  def list_types(scope, company_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(t in Tenancy.scope_query(ActionType, scope),
           where: t.company_id == ^company_id,
           order_by: [desc: t.active, asc: t.name, asc: t.id]
         )
       )
       |> Enum.map(&type_view/1)}
    end
  end

  def create_type(scope, company_id, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, _company} <- Access.current_company(scope, company_id) do
      %ActionType{tenant_id: Scope.tenant_id(scope), company_id: company_id, active: true}
      |> ActionType.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, type} -> {:ok, type_view(type)}
        error -> error
      end
    end
  end

  def set_type_active(scope, company_id, type_id, active) when is_boolean(active) do
    with {:ok, _company} <- Access.current_company(scope, company_id),
         %ActionType{} = type <- get_type(scope, company_id, type_id) || {:error, :not_found},
         {:ok, type} <- type |> Ecto.Changeset.change(active: active) |> Repo.update() do
      {:ok, type_view(type)}
    end
  end

  ## Proposal

  @doc """
  Proposes an action. With `assessment_id` it comes from the employee's current
  finalized assessment gap (or an expired critical certificate); without it the
  skill, employee, levels, criticality and a `manual_reason` are stated. The
  same `request_key` replays the earlier proposal.
  """
  def propose(actor, company_id, attrs) when is_map(attrs) do
    scope = actor.scope
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, _company} <- Access.authorize(actor, company_id, @manage),
         {:ok, key} <- Assessments.text(attrs["request_key"], 80, true),
         {:ok, input} <- normalize(attrs) do
      Access.transact(fn ->
        case find_by_key(scope, company_id, key) do
          nil -> create(actor, company_id, key, input, attrs)
          existing -> replay(existing, input)
        end
      end)
    else
      {:error, :blank} -> {:error, :invalid_action}
      error -> error
    end
  end

  def propose(_actor, _company_id, _attrs), do: {:error, :invalid_action}

  defp normalize(attrs) do
    today = Date.utc_today()

    with {:ok, type_id} <- Assessments.integer(attrs["action_type_id"]),
         {:ok, owner} <- Assessments.integer(attrs["owner_employee_id"]),
         {:ok, coordinator} <- Assessments.integer(attrs["coordinator_employee_id"]),
         {:ok, provider} <- Assessments.optional_integer(attrs["provider_employee_id"]),
         {:ok, provider_name} <- Assessments.text(attrs["provider_name"], 160, false),
         {:ok, objective} <- Assessments.text(attrs["objective"], 2000, true),
         {:ok, intervention} <- Assessments.text(attrs["intervention"], 2000, true),
         {:ok, evidence} <- Assessments.text(attrs["expected_evidence"], 2000, true),
         {:ok, next_steps} <- Assessments.text(attrs["next_steps"], 2000, false),
         {:ok, start_on} <- Assessments.date(attrs["start_on"], today),
         {:ok, due_on} <- Assessments.date(attrs["due_on"], nil),
         true <- due_on != nil and Date.compare(due_on, start_on) != :lt do
      {:ok,
       %{
         action_type_id: type_id,
         owner_employee_id: owner,
         coordinator_employee_id: coordinator,
         provider_employee_id: provider,
         provider_name: provider_name,
         objective: objective,
         intervention: intervention,
         expected_evidence: evidence,
         next_steps: next_steps,
         start_on: start_on,
         due_on: due_on
       }}
    else
      _ -> {:error, :invalid_action}
    end
  end

  defp create(actor, company_id, key, input, attrs) do
    scope = actor.scope

    with {:ok, source} <- source(scope, company_id, attrs),
         {:ok, type} <- action_type(scope, company_id, input),
         :ok <- provider_present(type, input),
         {:ok, employee} <- Access.current_employee(scope, company_id, source.employee_id),
         :ok <- current_people(scope, company_id, input),
         {:ok, policy} <- Policy.get(scope, company_id) do
      gap = max(source.target_level - source.starting_level, 0)
      multiplier = Policy.multiplier(policy, source.criticality)

      action =
        Repo.insert!(
          struct(
            %Action{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              employee_name: employee.display_name,
              gap_at_start: gap,
              priority_multiplier: multiplier,
              priority_score: gap * multiplier,
              priority_explanation:
                explanation(gap, source.criticality, multiplier, source.mandatory),
              status: "proposed",
              closure: "open",
              created_by_user_id: actor.id,
              request_key: key
            },
            Map.merge(
              Map.take(source, ~w(employee_id skill_id source_assessment_id starting_level
                                           target_level criticality mandatory manual_reason)a),
              input
            )
          )
        )

      event!(action, "proposed", nil, "proposed", actor.id, nil, nil)
      {:ok, view(action)}
    end
  end

  defp replay(existing, input) do
    if existing.objective == input.objective and existing.action_type_id == input.action_type_id,
      do: {:ok, view(existing)},
      else: {:error, :key_conflict}
  end

  # A gap proposal copies the assessed gap; a manual one states it.
  defp source(scope, company_id, %{"assessment_id" => id}) when id not in [nil, ""] do
    with {:ok, id} <- Assessments.integer(id),
         %Assessment{status: "finalized"} = assessment <-
           Assessments.get(scope, company_id, id) || {:error, :not_found},
         %Score{assessment_id: ^id} <- current_score(scope, company_id, assessment),
         true <- actionable?(assessment) || {:error, :not_actionable},
         false <- exists_for_assessment?(scope, company_id, id) do
      {:ok,
       %{
         employee_id: assessment.employee_id,
         skill_id: assessment.skill_id,
         source_assessment_id: assessment.id,
         starting_level: assessment.assessed_level,
         target_level: assessment.required_level,
         criticality: assessment.criticality,
         mandatory: assessment.mandatory,
         manual_reason: nil
       }}
    else
      true -> {:error, :already_proposed}
      %Assessment{} -> {:error, :not_actionable}
      nil -> {:error, :not_current}
      %Score{} -> {:error, :not_current}
      error -> error
    end
  end

  defp source(scope, company_id, attrs) do
    with {:ok, employee_id} <- Assessments.integer(attrs["employee_id"]),
         {:ok, skill_id} <- Assessments.integer(attrs["skill_id"]),
         {:ok, starting} <- Assessments.integer(attrs["starting_level"]),
         {:ok, target} <- Assessments.integer(attrs["target_level"]),
         {:ok, reason} <- Assessments.text(attrs["manual_reason"], 1000, true),
         criticality when criticality in @criticalities <- attrs["criticality"],
         true <- starting in 0..20 and target in 0..20,
         %Skill{active: true} <-
           Repo.one(
             from(s in Tenancy.scope_query(Skill, scope),
               where: s.company_id == ^company_id and s.id == ^skill_id
             )
           ) do
      {:ok,
       %{
         employee_id: employee_id,
         skill_id: skill_id,
         source_assessment_id: nil,
         starting_level: starting,
         target_level: target,
         criticality: criticality,
         mandatory: attrs["mandatory"] in [true, "true"],
         manual_reason: reason
       }}
    else
      {:error, :blank} -> {:error, :reason_required}
      _ -> {:error, :invalid_action}
    end
  end

  defp current_score(scope, company_id, assessment),
    do:
      Repo.one(
        from(s in Tenancy.scope_query(Score, scope),
          where:
            s.company_id == ^company_id and s.employee_id == ^assessment.employee_id and
              s.skill_id == ^assessment.skill_id
        )
      )

  defp actionable?(assessment) do
    expired? =
      assessment.criticality == "critical" and assessment.valid_until != nil and
        Date.compare(assessment.valid_until, Date.utc_today()) == :lt

    assessment.gap > 0 or expired?
  end

  defp exists_for_assessment?(scope, company_id, id),
    do:
      Repo.exists?(
        from(a in Tenancy.scope_query(Action, scope),
          where: a.company_id == ^company_id and a.source_assessment_id == ^id
        )
      )

  defp action_type(scope, company_id, input) do
    case get_type(scope, company_id, input.action_type_id) do
      %ActionType{active: true} = type -> {:ok, type}
      _ -> {:error, :type_unavailable}
    end
  end

  defp provider_present(%ActionType{requires_provider: true}, input) do
    if input.provider_employee_id != nil or input.provider_name != nil,
      do: :ok,
      else: {:error, :provider_required}
  end

  defp provider_present(_type, _input), do: :ok

  defp current_people(scope, company_id, input) do
    ids =
      Enum.reject(
        [input.owner_employee_id, input.coordinator_employee_id, input.provider_employee_id],
        &is_nil/1
      )

    with {:ok, employees} <- Access.employees_by_ids(scope, company_id, Enum.uniq(ids)),
         true <- length(employees) == length(Enum.uniq(ids)) do
      :ok
    else
      _ -> {:error, :employee_unavailable}
    end
  end

  defp explanation(gap, criticality, multiplier, mandatory) do
    gate =
      if mandatory,
        do: "Mandatory requirement: yes; escalated ahead of the others. ",
        else: "Mandatory requirement: no. "

    gate <> "Score #{gap * multiplier} = gap #{gap} x #{criticality} multiplier #{multiplier}."
  end

  ## Revision and approval

  @doc "Tailors a proposal; its gap snapshot never changes."
  def revise(actor, company_id, action_id, attrs) when is_map(attrs) do
    scope = actor.scope
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, _company} <- Access.authorize(actor, company_id, @manage),
         {:ok, input} <- normalize(attrs) do
      Access.transact(fn ->
        with %Action{status: "proposed"} = action <-
               locked(scope, company_id, action_id) || {:error, :not_found},
             {:ok, type} <- action_type(scope, company_id, input),
             :ok <- provider_present(type, input),
             :ok <- current_people(scope, company_id, input) do
          updated = action |> Ecto.Changeset.change(Map.to_list(input)) |> Repo.update!()
          event!(updated, "revised", "proposed", "proposed", actor.id, nil, nil)
          {:ok, view(updated)}
        else
          %Action{} -> {:error, :not_proposed}
          error -> error
        end
      end)
    end
  end

  @doc "Approves a proposal; the proposer and the employee cannot."
  def approve(actor, company_id, action_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @approve) do
      Access.transact(fn ->
        with %Action{status: "proposed"} = action <-
               locked(scope, company_id, action_id) || {:error, :not_found},
             :ok <- independent(scope, company_id, actor, action) do
          to =
            if Date.compare(action.start_on, Date.utc_today()) == :gt,
              do: "scheduled",
              else: "not_started"

          updated =
            action
            |> Ecto.Changeset.change(
              status: to,
              approved_by_user_id: actor.id,
              approved_at: Assessments.now()
            )
            |> Repo.update!()

          event!(updated, "approved", "proposed", to, actor.id, nil, nil)
          {:ok, view(updated)}
        else
          %Action{} -> {:error, :not_proposed}
          error -> error
        end
      end)
    end
  end

  defp independent(scope, company_id, actor, action) do
    linked = Access.linked_employee_id(scope, company_id, actor)

    if actor.id == action.created_by_user_id or linked == {:ok, action.employee_id},
      do: {:error, :self_approval},
      else: :ok
  end

  ## Lifecycle

  def start(actor, company_id, action_id),
    do:
      transition(
        actor,
        company_id,
        action_id,
        @open -- ["in_progress"],
        "in_progress",
        "started",
        %{}
      )

  def hold(actor, company_id, action_id, reason) do
    with {:ok, reason} <- required(reason, :reason_required) do
      transition(
        actor,
        company_id,
        action_id,
        ~w(not_started scheduled in_progress),
        "on_hold",
        "put_on_hold",
        %{comment: reason}
      )
    end
  end

  @doc "Records the completed intervention; a reassessment is then due."
  def complete(actor, company_id, action_id, evidence, reassessment_due_on) do
    with {:ok, evidence} <- required(evidence, :evidence_required),
         {:ok, due} <- Assessments.date(reassessment_due_on, nil),
         true <-
           (due != nil and Date.compare(due, Date.utc_today()) != :lt) || {:error, :invalid_date} do
      transition(
        actor,
        company_id,
        action_id,
        @open,
        "pending_reassessment",
        "intervention_completed",
        %{
          evidence: evidence,
          changes: [
            closure: "pending_reassessment",
            completed_at: Assessments.now(),
            completion_evidence: evidence,
            reassessment_due_on: due
          ]
        }
      )
    end
  end

  def cancel(actor, company_id, action_id, reason) do
    with {:ok, reason} <- required(reason, :reason_required) do
      transition(
        actor,
        company_id,
        action_id,
        ["proposed", "pending_reassessment" | @open],
        "cancelled",
        "cancelled",
        %{comment: reason, changes: [closure: "cancelled"]}
      )
    end
  end

  @doc "Closes an action pending reassessment with the employee's finalized reassessment."
  def link_reassessment(actor, company_id, action_id, assessment_id) do
    scope = actor.scope

    with {:ok, _company} <- authorize_progress(actor, company_id),
         {:ok, assessment_id} <- Assessments.integer(assessment_id) do
      Access.transact(fn ->
        with %Action{status: "pending_reassessment"} = action <-
               locked(scope, company_id, action_id) || {:error, :not_found},
             :ok <- may_progress(scope, company_id, actor, action),
             %Assessment{status: "finalized"} = assessment <-
               Assessments.get(scope, company_id, assessment_id) || {:error, :not_found},
             true <- follows?(assessment, action) || {:error, :not_a_reassessment} do
          closure =
            if assessment.assessed_level >= action.target_level,
              do: "closed_competent",
              else: "further_action_required"

          updated =
            action
            |> Ecto.Changeset.change(
              status: "completed",
              closure: closure,
              post_assessment_id: assessment.id,
              post_level: assessment.assessed_level,
              improvement: assessment.assessed_level - action.starting_level
            )
            |> Repo.update!()

          event!(
            updated,
            "reassessment_linked",
            "pending_reassessment",
            "completed",
            actor.id,
            nil,
            assessment.evidence
          )

          {:ok, view(updated)}
        else
          %Action{} -> {:error, :not_pending_reassessment}
          %Assessment{} -> {:error, :not_a_reassessment}
          error -> error
        end
      end)
    end
  end

  defp follows?(assessment, action) do
    assessment.employee_id == action.employee_id and assessment.skill_id == action.skill_id and
      assessment.id != action.source_assessment_id and
      Date.compare(assessment.assessed_on, NaiveDateTime.to_date(action.completed_at)) != :lt
  end

  def comment(actor, company_id, action_id, comment, evidence \\ nil) do
    scope = actor.scope

    with {:ok, _company} <- authorize_progress(actor, company_id),
         {:ok, comment} <- required(comment, :comment_required),
         {:ok, evidence} <- Assessments.text(evidence, 2000, false) do
      Access.transact(fn ->
        with %Action{} = action <- locked(scope, company_id, action_id) || {:error, :not_found},
             :ok <- may_progress(scope, company_id, actor, action) do
          event!(action, "commented", nil, nil, actor.id, comment, evidence)
          {:ok, view(action)}
        end
      end)
    end
  end

  defp transition(actor, company_id, action_id, from, to, event, opts) do
    scope = actor.scope

    with {:ok, _company} <- authorize_progress(actor, company_id) do
      Access.transact(fn ->
        with %Action{} = action <- locked(scope, company_id, action_id) || {:error, :not_found},
             :ok <- may_progress(scope, company_id, actor, action),
             true <- action.status in from || {:error, :invalid_transition} do
          updated =
            action
            |> Ecto.Changeset.change([{:status, to} | Map.get(opts, :changes, [])])
            |> Repo.update!()

          event!(updated, event, action.status, to, actor.id, opts[:comment], opts[:evidence])
          {:ok, view(updated)}
        end
      end)
    end
  end

  defp authorize_progress(actor, company_id),
    do: Access.authorize_any(actor, company_id, [@manage, @update])

  # Managers move any action; an owner moves the actions they own.
  defp may_progress(scope, company_id, actor, action) do
    cond do
      Access.allowed?(actor, company_id, @manage) ->
        :ok

      Access.linked_employee_id(scope, company_id, actor) == {:ok, action.owner_employee_id} ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  defp required(value, error) do
    case Assessments.text(value, 2000, true) do
      {:ok, text} -> {:ok, text}
      _ -> {:error, error}
    end
  end

  ## Reads

  @doc "Current employees a manager may name as owner, coordinator or provider."
  def people(actor, company_id) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @manage),
         {:ok, employees} <- Access.current_employees(actor.scope, company_id) do
      {:ok,
       employees
       |> Enum.map(
         &%{id: Access.employee_id(&1), name: "#{&1.display_name} (#{&1.employee_number})"}
       )
       |> Enum.sort_by(& &1.name)}
    end
  end

  @doc "Actions filtered by status group (`:open` or `:closed`) for viewers."
  def list(actor, company_id, group \\ :open) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @view) do
      {:ok, scope |> query(company_id, group) |> Repo.all() |> present(scope, company_id)}
    end
  end

  @doc "Actions the signed-in employee owns."
  def owned(actor, company_id, group \\ :open) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @update),
         {:ok, employee_id} <- Access.self_employee(scope, company_id, actor) do
      {:ok,
       scope
       |> query(company_id, group)
       |> where([a], a.owner_employee_id == ^employee_id)
       |> Repo.all()
       |> present(scope, company_id)}
    end
  end

  def events(actor, company_id, action_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize_any(actor, company_id, [@view, @manage, @update]),
         %Action{} = action <- get(scope, company_id, action_id) || {:error, :not_found},
         :ok <- may_read(scope, company_id, actor, action) do
      {:ok,
       Repo.all(
         from(e in Tenancy.scope_query(ActionEvent, scope),
           where: e.action_id == ^action.id,
           order_by: [asc: e.id],
           select:
             map(e, [
               :event_type,
               :from_status,
               :to_status,
               :comment,
               :evidence,
               :actor_user_id,
               :inserted_at
             ])
         )
       )}
    end
  end

  defp may_read(scope, company_id, actor, action) do
    if Access.allowed?(actor, company_id, @view),
      do: :ok,
      else: may_progress(scope, company_id, actor, action)
  end

  defp query(scope, company_id, group) do
    base =
      from(a in Tenancy.scope_query(Action, scope),
        where: a.company_id == ^company_id,
        limit: @limit
      )

    case group do
      :closed ->
        where(base, [a], a.status in ["completed", "cancelled"])
        |> order_by([a], desc: a.updated_at, desc: a.id)

      _open ->
        where(base, [a], a.status not in ["completed", "cancelled"])
        |> order_by([a], desc: a.mandatory, desc: a.priority_score, asc: a.due_on, asc: a.id)
    end
  end

  defp present(rows, scope, company_id) do
    skills = Assessments.skills(scope, Enum.map(rows, & &1.skill_id))

    types =
      Repo.all(
        from(t in Tenancy.scope_query(ActionType, scope),
          where: t.id in ^Enum.map(rows, & &1.action_type_id),
          select: {t.id, t.name}
        )
      )
      |> Map.new()

    names =
      case Access.names(
             scope,
             company_id,
             Enum.flat_map(rows, &[&1.owner_employee_id, &1.coordinator_employee_id])
           ) do
        {:ok, names} -> names
        _ -> %{}
      end

    Enum.map(rows, fn row ->
      row
      |> view()
      |> Map.merge(%{
        skill_name: skills |> Map.get(row.skill_id, %{}) |> Map.get(:name),
        type_name: Map.get(types, row.action_type_id),
        owner_name: Map.get(names, row.owner_employee_id, "Employee ##{row.owner_employee_id}"),
        coordinator_name:
          Map.get(names, row.coordinator_employee_id, "Employee ##{row.coordinator_employee_id}")
      })
    end)
  end

  ## Private

  defp get(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(a in Tenancy.scope_query(Action, scope),
          where: a.company_id == ^company_id and a.id == ^id
        )
      )

  defp get(_scope, _company_id, _id), do: nil

  defp locked(scope, company_id, id) do
    with {:ok, id} <- Assessments.integer(id) do
      Repo.one(
        from(a in Tenancy.scope_query(Action, scope),
          where: a.company_id == ^company_id and a.id == ^id,
          lock: "FOR UPDATE"
        )
      )
    else
      _ -> nil
    end
  end

  defp find_by_key(scope, company_id, key),
    do:
      Repo.one(
        from(a in Tenancy.scope_query(Action, scope),
          where: a.company_id == ^company_id and a.request_key == ^key
        )
      )

  defp get_type(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(t in Tenancy.scope_query(ActionType, scope),
          where: t.company_id == ^company_id and t.id == ^id
        )
      )

  defp get_type(_scope, _company_id, _id), do: nil

  defp event!(action, type, from, to, user_id, comment, evidence) do
    Repo.insert!(%ActionEvent{
      tenant_id: action.tenant_id,
      company_id: action.company_id,
      action_id: action.id,
      event_type: type,
      from_status: from,
      to_status: to,
      comment: comment,
      evidence: evidence,
      actor_user_id: user_id
    })
  end

  defp type_view(type), do: Map.take(type, [:id, :code, :name, :requires_provider, :active])

  @doc false
  def view(%Action{} = action) do
    Map.take(action, [
      :id,
      :employee_id,
      :employee_name,
      :skill_id,
      :source_assessment_id,
      :action_type_id,
      :starting_level,
      :target_level,
      :gap_at_start,
      :criticality,
      :mandatory,
      :priority_multiplier,
      :priority_score,
      :priority_explanation,
      :manual_reason,
      :objective,
      :intervention,
      :expected_evidence,
      :owner_employee_id,
      :coordinator_employee_id,
      :provider_employee_id,
      :provider_name,
      :start_on,
      :due_on,
      :status,
      :closure,
      :approved_by_user_id,
      :approved_at,
      :completed_at,
      :completion_evidence,
      :reassessment_due_on,
      :post_assessment_id,
      :post_level,
      :improvement,
      :next_steps,
      :created_by_user_id
    ])
  end
end
