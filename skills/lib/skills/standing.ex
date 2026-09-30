defmodule Bilimbi.People.Skills.Standing do
  @moduledoc false
  # Read models over the current scores: an employee's own standing, the gaps
  # in the actor's reach, and critical-skill backup coverage.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy

  alias Bilimbi.People.Skills.{
    Access,
    Action,
    Assessments,
    Policy,
    ReassessmentRequest,
    Score,
    Skill
  }

  @view "people.skills.assessments.view"
  @wide "people.skills.assessments.manage"
  @self "people.skills.self.view"
  @limit 500

  @score_fields [
    :employee_id,
    :skill_id,
    :assessment_id,
    :required_level,
    :current_level,
    :gap,
    :criticality,
    :mandatory,
    :priority_score,
    :assessed_on,
    :valid_until,
    :next_due_on
  ]

  @doc "Scores with a gap inside the actor's reach, mandatory and highest priority first."
  def gaps(actor, company_id) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @view),
         {:ok, reach} <- Access.reach(actor, company_id, @wide) do
      query =
        from(s in Tenancy.scope_query(Score, actor.scope),
          where: s.company_id == ^company_id and s.gap > 0,
          order_by: [desc: s.mandatory, desc: s.priority_score, asc: s.next_due_on, asc: s.id],
          limit: @limit
        )

      query =
        case reach do
          :company -> query
          {:team, team} -> where(query, [s], s.employee_id in ^MapSet.to_list(team))
        end

      {:ok, query |> Repo.all() |> present(actor.scope, company_id)}
    end
  end

  @doc """
  The signed-in employee's own scores with their review state, open
  development actions and pending reassessment requests.
  """
  def own(actor, company_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @self),
         {:ok, employee_id} <- Access.self_employee(scope, company_id, actor) do
      scores =
        from(s in Tenancy.scope_query(Score, scope),
          where: s.company_id == ^company_id and s.employee_id == ^employee_id,
          order_by: [asc: s.skill_id],
          limit: @limit
        )
        |> Repo.all()
        |> present(scope, company_id)

      actions =
        from(a in Tenancy.scope_query(Action, scope),
          where:
            a.company_id == ^company_id and a.employee_id == ^employee_id and
              a.status not in ["proposed", "cancelled"],
          order_by: [asc: a.due_on, asc: a.id],
          limit: @limit
        )
        |> Repo.all()

      skills = Assessments.skills(scope, Enum.map(actions, & &1.skill_id))

      requests =
        from(r in Tenancy.scope_query(ReassessmentRequest, scope),
          where:
            r.company_id == ^company_id and r.employee_id == ^employee_id and
              r.status == "pending",
          order_by: [asc: r.due_on]
        )
        |> Repo.all()

      {:ok,
       %{
         employee_id: employee_id,
         scores: scores,
         actions:
           Enum.map(actions, fn action ->
             action
             |> Map.take([
               :id,
               :skill_id,
               :status,
               :closure,
               :starting_level,
               :target_level,
               :objective,
               :start_on,
               :due_on,
               :post_level,
               :improvement
             ])
             |> Map.put(:skill_name, skill_name(skills, action.skill_id))
           end),
         reassessments:
           Enum.map(requests, fn request ->
             %{
               id: request.id,
               skill_id: request.skill_id,
               skill_name:
                 skill_name(Assessments.skills(scope, [request.skill_id]), request.skill_id),
               due_on: request.due_on
             }
           end)
       }}
    end
  end

  @doc """
  Critical skills and how many working employees hold each at the level their
  own requirement asks, with a current validity. A skill is covered when the
  holders reach the company's backup minimum. Company-wide holders only.
  """
  def coverage(actor, company_id, as_of \\ Date.utc_today()) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @view),
         {:ok, :company} <- coverage_reach(actor, company_id),
         do: critical_coverage(actor.scope, company_id, as_of)
  end

  @doc false
  # Unauthorized: callers must have authorized the actor another way.
  def critical_coverage(scope, company_id, as_of) do
    with {:ok, policy} <- Policy.get(scope, company_id),
         {:ok, employees} <- Access.current_employees(scope, company_id) do
      working = MapSet.new(employees, &Access.employee_id/1)

      skills =
        Repo.all(
          from(s in Tenancy.scope_query(Skill, scope),
            where: s.company_id == ^company_id and s.active and s.critical,
            order_by: [asc: s.name, asc: s.id],
            select: map(s, [:id, :code, :name])
          )
        )

      holders =
        from(s in Tenancy.scope_query(Score, scope),
          where:
            s.company_id == ^company_id and s.current_level >= s.required_level and
              s.skill_id in ^Enum.map(skills, & &1.id) and
              (is_nil(s.valid_until) or s.valid_until >= ^as_of),
          select: {s.skill_id, s.employee_id}
        )
        |> Repo.all()
        |> Enum.filter(fn {_skill, employee} -> MapSet.member?(working, employee) end)
        |> Enum.frequencies_by(&elem(&1, 0))

      {:ok,
       Enum.map(skills, fn skill ->
         count = Map.get(holders, skill.id, 0)

         Map.merge(skill, %{
           skill_id: skill.id,
           holders: count,
           minimum: policy.backup_minimum,
           covered: count >= policy.backup_minimum
         })
       end)}
    end
  end

  defp coverage_reach(actor, company_id) do
    if Access.allowed?(actor, company_id, @wide),
      do: {:ok, :company},
      else: {:error, :out_of_reach}
  end

  defp present(rows, scope, company_id) do
    skills = Assessments.skills(scope, Enum.map(rows, & &1.skill_id))

    names =
      case Access.names(scope, company_id, Enum.map(rows, & &1.employee_id)) do
        {:ok, names} -> names
        _ -> %{}
      end

    today = Date.utc_today()
    assessment_ids = Enum.map(rows, & &1.assessment_id)

    provenance =
      from(a in Tenancy.scope_query(Bilimbi.People.Skills.Assessment, scope),
        join: p in Bilimbi.People.Skills.Profile,
        on: p.id == a.profile_id and p.tenant_id == a.tenant_id and p.company_id == a.company_id,
        where: a.company_id == ^company_id and a.id in ^assessment_ids,
        select:
          {a.id, %{profile_id: a.profile_id, profile_version: p.version, scale_id: a.scale_id}}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, fn row ->
      skill = Map.get(skills, row.skill_id)

      assessment = Map.get(provenance, row.assessment_id)

      row
      |> Map.take(@score_fields)
      |> Map.merge(%{
        assessment_profile_id: assessment && assessment.profile_id,
        assessment_profile_version: assessment && assessment.profile_version,
        assessment_scale_id: assessment && assessment.scale_id,
        employee_name: Map.get(names, row.employee_id, "Employee ##{row.employee_id}"),
        skill_code: skill && skill.code,
        skill_name: skill && skill.name,
        result_band: Assessments.band(row.gap, row.current_level, row.required_level),
        state: state(row, today)
      })
    end)
  end

  defp state(row, today) do
    cond do
      row.valid_until && Date.compare(row.valid_until, today) == :lt -> :expired
      Date.compare(row.next_due_on, today) != :gt -> :overdue
      true -> :current
    end
  end

  defp skill_name(skills, id), do: skills |> Map.get(id, %{}) |> Map.get(:name)
end
