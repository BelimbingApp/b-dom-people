defmodule Bilimbi.People.Skills.Assessments do
  @moduledoc false
  # Evidence-backed skill assessments behind the `Bilimbi.People.Skills` facade.
  #
  # An assessor submits a level with evidence against the requirement version in
  # force for the employee on the assessment date. A reviewer who is neither the
  # assessor nor the assessed employee verifies or returns it; a finalizer with
  # the same independence finalizes a verified assessment, which refreshes the
  # employee's current score. Assessments and their decisions are facts: a
  # correction is a new assessment that supersedes the earlier one.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee

  alias Bilimbi.People.Skills

  alias Bilimbi.People.Skills.{
    Access,
    Assessment,
    AssessmentDecision,
    Policy,
    Score,
    Skill
  }

  @submit "people.skills.assessments.submit"
  @review "people.skills.assessments.review"
  @finalize "people.skills.assessments.approve"
  @view "people.skills.assessments.view"
  @wide "people.skills.assessments.manage"
  @list_limit 200

  @view_fields [
    :id,
    :employee_id,
    :skill_id,
    :profile_id,
    :scale_id,
    :required_level,
    :criticality,
    :weight_percent,
    :mandatory,
    :assessed_level,
    :gap,
    :priority_multiplier,
    :priority_score,
    :result_band,
    :method,
    :evidence,
    :notes,
    :assessed_on,
    :valid_until,
    :next_due_on,
    :status,
    :assessor_user_id,
    :reviewed_by_user_id,
    :reviewed_at,
    :review_note,
    :finalized_by_user_id,
    :finalized_at,
    :supersedes_assessment_id
  ]

  ## Submit

  @doc """
  Submits an assessment for review. The assessor must reach the employee (the
  reporting line, or everyone for company-wide holders) and cannot assess
  themselves. The same `request_key` from the same assessor replays the earlier
  submission; a different assessment under that key is refused. `opts[:reach]`
  is `:any` only for callers that already authorized the actor another way.
  """
  def submit(actor, company_id, attrs, opts \\ [])

  def submit(actor, company_id, attrs, opts) when is_map(attrs) do
    with {:ok, input} <- prepare(actor, company_id, attrs, opts) do
      Access.transact(fn -> write(actor, company_id, input) end)
    end
  end

  def submit(_actor, _company_id, _attrs, _opts), do: {:error, :invalid_assessment}

  @doc false
  # Authorizes and validates a submission before any lock is taken.
  def prepare(actor, company_id, attrs, opts) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @submit),
         {:ok, input} <- normalize(attrs),
         :ok <- not_self(actor.scope, company_id, actor, input.employee_id),
         {:ok, reach} <- assessor_reach(actor, company_id, opts),
         true <- Access.within?(reach, input.employee_id) || {:error, :out_of_reach} do
      {:ok, input}
    end
  end

  @doc false
  # Must run inside a transaction: locks the employee, then inserts or replays.
  def write(actor, company_id, input) do
    scope = actor.scope

    with {:ok, _proof} <- Employee.lock_affiliation(scope, company_id, input.employee_id),
         {:ok, _employee} <- Access.current_employee(scope, company_id, input.employee_id) do
      case find_by_key(scope, company_id, actor.id, input.request_key) do
        nil -> insert(actor, company_id, input)
        existing -> replay(existing, input)
      end
    end
  end

  defp assessor_reach(_actor, _company_id, reach: :any), do: {:ok, :company}
  defp assessor_reach(actor, company_id, _opts), do: Access.reach(actor, company_id, @wide)

  defp not_self(scope, company_id, actor, employee_id) do
    case Access.linked_employee_id(scope, company_id, actor) do
      {:ok, ^employee_id} -> {:error, :self_assessment}
      _ -> :ok
    end
  end

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    today = Date.utc_today()

    with {:ok, employee_id} <- integer(attrs["employee_id"]),
         {:ok, skill_id} <- integer(attrs["skill_id"]),
         {:ok, level} <- integer(attrs["assessed_level"]),
         {:ok, evidence} <- text(attrs["evidence"], 4000, true),
         {:ok, assessed_on} <- date(attrs["assessed_on"], today),
         {:ok, valid_until} <- optional_date(attrs["valid_until"]),
         {:ok, method} <- text(attrs["method"], 80, false),
         {:ok, notes} <- text(attrs["notes"], 2000, false),
         {:ok, key} <- text(attrs["request_key"], 80, true),
         {:ok, supersedes} <- optional_integer(attrs["supersedes_assessment_id"]),
         true <- Date.compare(assessed_on, today) != :gt || {:error, :future_assessment},
         true <-
           (valid_until == nil or Date.compare(valid_until, assessed_on) != :lt) ||
             {:error, :invalid_validity} do
      {:ok,
       %{
         employee_id: employee_id,
         skill_id: skill_id,
         assessed_level: level,
         evidence: evidence,
         assessed_on: assessed_on,
         valid_until: valid_until,
         method: method,
         notes: notes,
         request_key: key,
         supersedes_assessment_id: supersedes
       }}
    else
      {:error, reason} when reason in [:future_assessment, :invalid_validity] ->
        {:error, reason}

      _ ->
        {:error, :invalid_assessment}
    end
  end

  defp insert(actor, company_id, input) do
    scope = actor.scope
    user_id = actor.id

    with {:ok, skill} <- active_skill(scope, company_id, input.skill_id),
         {:ok, requirement} <- requirement(scope, company_id, input),
         :ok <- level_on_scale(scope, company_id, requirement.profile.scale_id, input),
         {:ok, policy} <- Policy.get(scope, company_id),
         :ok <- supersession(scope, company_id, input, user_id) do
      item = requirement.item
      gap = max(item.required_level - input.assessed_level, 0)
      multiplier = Policy.multiplier(policy, item.criticality)

      row =
        Repo.insert!(%Assessment{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          employee_id: input.employee_id,
          skill_id: skill.id,
          profile_id: requirement.profile.id,
          scale_id: requirement.profile.scale_id,
          required_level: item.required_level,
          criticality: item.criticality,
          weight_percent: item.weight_percent,
          mandatory: item.mandatory,
          assessed_level: input.assessed_level,
          gap: gap,
          priority_multiplier: multiplier,
          priority_score: gap * multiplier,
          result_band: band(gap, input.assessed_level, item.required_level),
          method: input.method,
          evidence: input.evidence,
          notes: input.notes,
          assessed_on: input.assessed_on,
          valid_until: input.valid_until,
          next_due_on: next_due(input, skill, policy),
          status: "pending_review",
          assessor_user_id: user_id,
          supersedes_assessment_id: input.supersedes_assessment_id,
          request_key: input.request_key
        })

      decide!(row, "submitted", user_id, nil)
      {:ok, view(row)}
    end
  end

  defp replay(existing, input) do
    same? =
      existing.employee_id == input.employee_id and existing.skill_id == input.skill_id and
        existing.assessed_level == input.assessed_level and
        existing.assessed_on == input.assessed_on and existing.evidence == input.evidence

    if same?, do: {:ok, view(existing)}, else: {:error, :key_conflict}
  end

  defp find_by_key(scope, company_id, user_id, key),
    do:
      Repo.one(
        from(a in Tenancy.scope_query(Assessment, scope),
          where:
            a.company_id == ^company_id and a.assessor_user_id == ^user_id and
              a.request_key == ^key
        )
      )

  defp active_skill(scope, company_id, skill_id) do
    case Repo.one(
           from(s in Tenancy.scope_query(Skill, scope),
             where: s.company_id == ^company_id and s.id == ^skill_id
           )
         ) do
      %Skill{active: true} = skill -> {:ok, skill}
      _ -> {:error, :skill_unavailable}
    end
  end

  defp requirement(scope, company_id, input) do
    with {:ok, position_id} <-
           Skills.position_of(scope, company_id, input.employee_id, input.assessed_on),
         {:ok, %{} = profile} <-
           Skills.requirements(scope, company_id, position_id, input.assessed_on),
         %{} = item <- Enum.find(profile.items, &(&1.skill_id == input.skill_id)) do
      {:ok, %{profile: profile, item: item}}
    else
      {:ok, nil} -> {:error, :no_requirement}
      nil -> {:error, :no_requirement}
      {:error, :ambiguous} -> {:error, :no_requirement}
      error -> error
    end
  end

  defp level_on_scale(scope, company_id, scale_id, input) do
    with {:ok, scales} <- Skills.list_scales(scope, company_id),
         %{levels: levels} <- Enum.find(scales, &(&1.id == scale_id)),
         true <- Enum.any?(levels, &(&1.level == input.assessed_level)) do
      :ok
    else
      _ -> {:error, :level_not_on_scale}
    end
  end

  defp supersession(_scope, _company_id, %{supersedes_assessment_id: nil}, _user_id), do: :ok

  defp supersession(scope, company_id, input, user_id) do
    prior =
      Repo.one(
        from(a in Tenancy.scope_query(Assessment, scope),
          where: a.company_id == ^company_id and a.id == ^input.supersedes_assessment_id,
          lock: "FOR UPDATE"
        )
      )

    cond do
      prior == nil or prior.employee_id != input.employee_id or
          prior.skill_id != input.skill_id ->
        {:error, :not_supersedable}

      prior.status == "returned" and prior.assessor_user_id != user_id ->
        {:error, :not_original_assessor}

      prior.status not in ["returned", "finalized"] ->
        {:error, :not_supersedable}

      Repo.exists?(
        from(a in Tenancy.scope_query(Assessment, scope),
          where: a.supersedes_assessment_id == ^prior.id
        )
      ) ->
        {:error, :already_superseded}

      true ->
        :ok
    end
  end

  defp next_due(%{valid_until: %Date{} = until}, _skill, _policy), do: until

  defp next_due(input, skill, policy),
    do:
      add_months(
        input.assessed_on,
        skill.reassessment_months || policy.default_reassessment_months
      )

  @doc false
  def add_months(%Date{year: year, month: month, day: day}, months) do
    index = year * 12 + (month - 1) + months
    {new_year, new_month} = {div(index, 12), rem(index, 12) + 1}
    Date.new!(new_year, new_month, min(day, Calendar.ISO.days_in_month(new_year, new_month)))
  end

  @doc false
  def band(0, assessed, required) when assessed > required, do: "exceeds"
  def band(0, _assessed, _required), do: "meets"
  def band(1, _assessed, _required), do: "minor_gap"
  def band(2, _assessed, _required), do: "major_gap"
  def band(_gap, _assessed, _required), do: "critical_gap"

  ## Review and finalization

  @doc """
  Verifies or returns a pending assessment. The assessor and the assessed
  employee cannot review it, and a return needs a note. The reviewer must reach
  the employee.
  """
  def review(actor, company_id, assessment_id, decision, note)
      when decision in [:verify, :return] do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @review),
         {:ok, reach} <- Access.reach(actor, company_id, @wide),
         {:ok, note} <- note(note, decision == :return) do
      Access.transact(fn ->
        with %Assessment{status: "pending_review"} = row <-
               locked(scope, company_id, assessment_id) || {:error, :not_found},
             true <- Access.within?(reach, row.employee_id) || {:error, :out_of_reach},
             :ok <- independent(scope, company_id, actor, row) do
          {status, kind} =
            if decision == :verify, do: {"verified", "verified"}, else: {"returned", "returned"}

          updated =
            row
            |> Ecto.Changeset.change(
              status: status,
              reviewed_by_user_id: actor.id,
              reviewed_at: now(),
              review_note: note
            )
            |> Repo.update!()

          decide!(updated, kind, actor.id, note)
          {:ok, view(updated)}
        else
          %Assessment{} -> {:error, :not_pending}
          error -> error
        end
      end)
    end
  end

  def review(_actor, _company_id, _assessment_id, _decision, _note),
    do: {:error, :invalid_decision}

  @doc """
  Finalizes a verified assessment and refreshes the employee's current score
  for the skill. The assessor and the assessed employee cannot finalize it.
  """
  def finalize(actor, company_id, assessment_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @finalize) do
      Access.transact(fn ->
        with %Assessment{status: "verified"} = row <-
               locked(scope, company_id, assessment_id) || {:error, :not_found},
             :ok <- independent(scope, company_id, actor, row) do
          updated =
            row
            |> Ecto.Changeset.change(
              status: "finalized",
              finalized_by_user_id: actor.id,
              finalized_at: now()
            )
            |> Repo.update!()

          decide!(updated, "finalized", actor.id, nil)
          refresh_score!(scope, updated)
          {:ok, view(updated)}
        else
          %Assessment{} -> {:error, :not_verified}
          error -> error
        end
      end)
    end
  end

  defp independent(scope, company_id, actor, row) do
    linked = Access.linked_employee_id(scope, company_id, actor)

    cond do
      actor.id == row.assessor_user_id -> {:error, :self_approval}
      linked == {:ok, row.employee_id} -> {:error, :self_approval}
      true -> :ok
    end
  end

  defp note(value, required?) do
    case text(value, 2000, required?) do
      {:ok, note} -> {:ok, note}
      _ -> {:error, if(required?, do: :note_required, else: :invalid_note)}
    end
  end

  # The current score is the newest finalized assessment that no finalized
  # correction supersedes, directly or through a chain of corrections.
  defp refresh_score!(scope, %Assessment{} = row) do
    rows =
      Repo.all(
        from(a in Tenancy.scope_query(Assessment, scope),
          where:
            a.company_id == ^row.company_id and a.employee_id == ^row.employee_id and
              a.skill_id == ^row.skill_id,
          order_by: [desc: a.assessed_on, desc: a.id]
        )
      )

    by_id = Map.new(rows, &{&1.id, &1})

    replaced =
      for a <- rows,
          a.status == "finalized",
          id <- ancestors(by_id, a.supersedes_assessment_id),
          into: MapSet.new(),
          do: id

    latest =
      Enum.find(rows, &(&1.status == "finalized" and not MapSet.member?(replaced, &1.id)))

    Repo.insert!(
      %Score{
        tenant_id: latest.tenant_id,
        company_id: latest.company_id,
        employee_id: latest.employee_id,
        skill_id: latest.skill_id,
        assessment_id: latest.id,
        profile_id: latest.profile_id,
        required_level: latest.required_level,
        current_level: latest.assessed_level,
        gap: latest.gap,
        criticality: latest.criticality,
        mandatory: latest.mandatory,
        priority_score: latest.priority_score,
        assessed_on: latest.assessed_on,
        valid_until: latest.valid_until,
        next_due_on: latest.next_due_on
      },
      on_conflict:
        {:replace,
         [
           :assessment_id,
           :profile_id,
           :required_level,
           :current_level,
           :gap,
           :criticality,
           :mandatory,
           :priority_score,
           :assessed_on,
           :valid_until,
           :next_due_on,
           :updated_at
         ]},
      conflict_target: [:company_id, :employee_id, :skill_id]
    )
  end

  defp ancestors(_by_id, nil), do: []

  defp ancestors(by_id, id),
    do: [id | ancestors(by_id, by_id |> Map.fetch!(id) |> Map.get(:supersedes_assessment_id))]

  ## Reads

  @doc """
  The employees the actor may assess or ask to be reassessed: everyone for
  company-wide holders, otherwise the people who report to them, never the
  actor themselves.
  """
  def assessable(actor, company_id) do
    scope = actor.scope

    with {:ok, _company} <-
           Access.authorize_any(actor, company_id, [@submit, "people.skills.reassessments.submit"]),
         {:ok, reach} <- Access.reach(actor, company_id, @wide),
         {:ok, employees} <- Access.current_employees(scope, company_id) do
      own = Access.linked_employee_id(scope, company_id, actor)

      {:ok,
       for employee <- employees,
           id = Access.employee_id(employee),
           Access.within?(reach, id),
           own != {:ok, id} do
         %{id: id, name: "#{employee.display_name} (#{employee.employee_number})"}
       end
       |> Enum.sort_by(& &1.name)}
    end
  end

  @doc "Assessments within the actor's reach, newest first."
  def list(actor, company_id, filters \\ %{}) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @view),
         {:ok, reach} <- Access.reach(actor, company_id, @wide) do
      {:ok,
       actor.scope
       |> base_query(company_id, reach)
       |> filter(filters)
       |> order_by([a], desc: a.id)
       |> limit(@list_limit)
       |> Repo.all()
       |> present(actor.scope, company_id)}
    end
  end

  @doc """
  The work waiting on the actor: assessments to review within their reach,
  verified assessments to finalize, and their own returned assessments that no
  correction has replaced.
  """
  def queue(actor, company_id) do
    scope = actor.scope

    with {:ok, _company} <-
           Access.authorize_any(actor, company_id, [@view, @submit, @review, @finalize]),
         {:ok, reach} <- Access.reach(actor, company_id, @wide) do
      linked = Access.linked_employee_id(scope, company_id, actor)
      own = fn a -> a.assessor_user_id == actor.id or linked == {:ok, a.employee_id} end

      review =
        if Access.allowed?(actor, company_id, @review),
          do: pending_by_status(scope, company_id, reach, "pending_review", own),
          else: []

      finalize =
        if Access.allowed?(actor, company_id, @finalize),
          do: pending_by_status(scope, company_id, :company, "verified", own),
          else: []

      returned =
        scope
        |> base_query(company_id, :company)
        |> where(
          [a],
          a.status == "returned" and a.assessor_user_id == ^actor.id and
            not exists(
              from(s in Assessment, where: s.supersedes_assessment_id == parent_as(:scoped).id)
            )
        )
        |> order_by([a], asc: a.id)
        |> limit(@list_limit)
        |> Repo.all()

      all = present(review ++ finalize ++ returned, scope, company_id)
      by_id = Map.new(all, &{&1.id, &1})

      {:ok,
       %{
         review: Enum.map(review, &Map.fetch!(by_id, &1.id)),
         finalize: Enum.map(finalize, &Map.fetch!(by_id, &1.id)),
         returned: Enum.map(returned, &Map.fetch!(by_id, &1.id))
       }}
    end
  end

  defp pending_by_status(scope, company_id, reach, status, own) do
    scope
    |> base_query(company_id, reach)
    |> where([a], a.status == ^status)
    |> order_by([a], asc: a.id)
    |> limit(@list_limit)
    |> Repo.all()
    |> Enum.reject(own)
  end

  @doc "The decision trail of one assessment within the actor's reach."
  def decisions(actor, company_id, assessment_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @view),
         {:ok, reach} <- Access.reach(actor, company_id, @wide),
         %Assessment{} = row <- get(scope, company_id, assessment_id) || {:error, :not_found},
         true <- Access.within?(reach, row.employee_id) || {:error, :not_found} do
      {:ok,
       Repo.all(
         from(d in Tenancy.scope_query(AssessmentDecision, scope),
           where: d.assessment_id == ^row.id,
           order_by: [asc: d.id],
           select: map(d, [:decision, :actor_user_id, :note, :inserted_at])
         )
       )}
    end
  end

  @doc false
  def get(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(a in Tenancy.scope_query(Assessment, scope),
          where: a.company_id == ^company_id and a.id == ^id
        )
      )

  def get(_scope, _company_id, _id), do: nil

  defp locked(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(a in Tenancy.scope_query(Assessment, scope),
          where: a.company_id == ^company_id and a.id == ^id,
          lock: "FOR UPDATE"
        )
      )

  defp locked(_scope, _company_id, _id), do: nil

  defp base_query(scope, company_id, reach) do
    query = from(a in Tenancy.scope_query(Assessment, scope), where: a.company_id == ^company_id)

    case reach do
      :company -> query
      {:team, team} -> where(query, [a], a.employee_id in ^MapSet.to_list(team))
    end
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, query when is_binary(status) and status != "" ->
        where(query, [a], a.status == ^status)

      {:employee_id, id}, query when is_integer(id) ->
        where(query, [a], a.employee_id == ^id)

      {:skill_id, id}, query when is_integer(id) ->
        where(query, [a], a.skill_id == ^id)

      _other, query ->
        query
    end)
  end

  @doc false
  def present(rows, scope, company_id) do
    skills = skills(scope, Enum.map(rows, & &1.skill_id))

    names =
      case Access.names(scope, company_id, Enum.map(rows, & &1.employee_id)) do
        {:ok, names} -> names
        _ -> %{}
      end

    Enum.map(rows, fn row ->
      skill = Map.get(skills, row.skill_id)

      row
      |> view()
      |> Map.merge(%{
        employee_name: Map.get(names, row.employee_id, "Employee ##{row.employee_id}"),
        skill_code: skill && skill.code,
        skill_name: skill && skill.name
      })
    end)
  end

  @doc false
  def skills(_scope, []), do: %{}

  def skills(scope, ids) do
    Repo.all(
      from(s in Tenancy.scope_query(Skill, scope),
        where: s.id in ^Enum.uniq(ids),
        select: map(s, [:id, :code, :name, :critical])
      )
    )
    |> Map.new(&{&1.id, &1})
  end

  @doc false
  def view(%Assessment{} = row), do: Map.take(row, @view_fields)

  defp decide!(row, decision, user_id, note) do
    Repo.insert!(%AssessmentDecision{
      tenant_id: row.tenant_id,
      company_id: row.company_id,
      assessment_id: row.id,
      decision: decision,
      actor_user_id: user_id,
      note: note
    })
  end

  ## Input

  @doc false
  def integer(value) when is_integer(value), do: {:ok, value}

  def integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_number}
    end
  end

  def integer(_value), do: {:error, :invalid_number}

  @doc false
  def optional_integer(value) when value in [nil, ""], do: {:ok, nil}
  def optional_integer(value), do: integer(value)

  @doc false
  def text(nil, _max, false), do: {:ok, nil}
  def text(nil, _max, true), do: {:error, :blank}

  def text(value, max, required?) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" and required? -> {:error, :blank}
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, :too_long}
      true -> {:ok, trimmed}
    end
  end

  def text(_value, _max, _required?), do: {:error, :invalid_text}

  @doc false
  def date(nil, default), do: {:ok, default}
  def date("", default), do: {:ok, default}
  def date(%Date{} = date, _default), do: {:ok, date}

  def date(value, _default) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  def date(_value, _default), do: {:error, :invalid_date}

  @doc false
  def optional_date(value) when value in [nil, ""], do: {:ok, nil}
  def optional_date(value), do: date(value, nil)

  @doc false
  def now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
