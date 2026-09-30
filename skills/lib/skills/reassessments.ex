defmodule Bilimbi.People.Skills.Reassessments do
  @moduledoc false
  # Reassessment requests. A team lead asks for an employee's skill to be
  # assessed again; a performer answers with a normal assessment, which then
  # follows the same review and finalization as any other, so a request never
  # moves a score. One request per employee and skill is open at a time.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Skills.{Access, Assessments, Policy, ReassessmentRequest, Score, Skill}

  @request "people.skills.reassessments.submit"
  @perform "people.skills.reassessments.execute"
  @wide "people.skills.assessments.manage"
  @limit 200

  @doc """
  Opens a request for an employee in the actor's reach. The employee needs a
  current score for the skill, and cannot be the requester. It falls due after
  the company's reassessment window.
  """
  def request(actor, company_id, employee_id, skill_id, reason) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @request),
         {:ok, reach} <- Access.reach(actor, company_id, @wide),
         {:ok, employee_id} <- Assessments.integer(employee_id),
         {:ok, skill_id} <- Assessments.integer(skill_id),
         {:ok, reason} <- Assessments.text(reason, 1000, true),
         false <- Access.linked_employee_id(scope, company_id, actor) == {:ok, employee_id},
         true <- Access.within?(reach, employee_id) || {:error, :out_of_reach},
         {:ok, policy} <- Policy.get(scope, company_id) do
      Access.transact(fn ->
        with {:ok, _employee} <- Access.current_employee(scope, company_id, employee_id),
             true <- scored?(scope, company_id, employee_id, skill_id) || {:error, :no_score},
             :ok <- not_open(scope, company_id, employee_id, skill_id) do
          row =
            Repo.insert!(%ReassessmentRequest{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              employee_id: employee_id,
              skill_id: skill_id,
              reason: reason,
              requested_by_user_id: actor.id,
              due_on: Date.add(Date.utc_today(), policy.reassessment_due_days),
              status: "pending"
            })

          {:ok, view(row)}
        end
      end)
    else
      true -> {:error, :self_request}
      {:error, :blank} -> {:error, :reason_required}
      error -> error
    end
  end

  @doc "Pending requests: all of them for performers, otherwise the actor's own."
  def pending(actor, company_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize_any(actor, company_id, [@perform, @request]) do
      query =
        from(r in Tenancy.scope_query(ReassessmentRequest, scope),
          where: r.company_id == ^company_id and r.status == "pending",
          order_by: [asc: r.due_on, asc: r.id],
          limit: @limit
        )

      query =
        if Access.allowed?(actor, company_id, @perform),
          do: query,
          else: where(query, [r], r.requested_by_user_id == ^actor.id)

      rows = Repo.all(query)
      skills = Assessments.skills(scope, Enum.map(rows, & &1.skill_id))

      names =
        case Access.names(scope, company_id, Enum.map(rows, & &1.employee_id)) do
          {:ok, names} -> names
          _ -> %{}
        end

      {:ok,
       Enum.map(rows, fn row ->
         row
         |> view()
         |> Map.merge(%{
           employee_name: Map.get(names, row.employee_id, "Employee ##{row.employee_id}"),
           skill_name: skills |> Map.get(row.skill_id, %{}) |> Map.get(:name)
         })
       end)}
    end
  end

  @doc "Cancels a pending request; its requester or a performer may."
  def cancel(actor, company_id, request_id) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize_any(actor, company_id, [@perform, @request]) do
      Access.transact(fn ->
        with %ReassessmentRequest{status: "pending"} = row <-
               locked(scope, company_id, request_id) || {:error, :not_found},
             true <-
               (row.requested_by_user_id == actor.id or
                  Access.allowed?(actor, company_id, @perform)) || {:error, :not_found} do
          updated =
            row
            |> Ecto.Changeset.change(
              status: "cancelled",
              cancelled_by_user_id: actor.id,
              cancelled_at: Assessments.now()
            )
            |> Repo.update!()

          {:ok, view(updated)}
        else
          %ReassessmentRequest{} -> {:error, :not_pending}
          error -> error
        end
      end)
    end
  end

  @doc """
  Performs a pending request by submitting the reassessment as the actor, who
  must hold the perform and submit capabilities. Attributes are the assessment's
  `assessed_level`, `evidence`, and optionally `assessed_on`, `method`, `notes`
  and `valid_until`; the employee and skill come from the request.
  """
  def perform(actor, company_id, request_id, attrs) when is_map(attrs) do
    scope = actor.scope

    with {:ok, _company} <- Access.authorize(actor, company_id, @perform),
         {:ok, request_id} <- Assessments.integer(request_id),
         %ReassessmentRequest{status: "pending"} = peek <-
           get(scope, company_id, request_id) || {:error, :not_found},
         attrs =
           attrs
           |> Map.new(fn {key, value} -> {to_string(key), value} end)
           |> Map.take(~w(assessed_level evidence assessed_on method notes valid_until))
           |> Map.merge(%{
             "employee_id" => peek.employee_id,
             "skill_id" => peek.skill_id,
             "request_key" => "reassessment:#{peek.id}"
           }),
         {:ok, input} <- Assessments.prepare(actor, company_id, attrs, reach: :any) do
      Access.transact(fn ->
        with %ReassessmentRequest{status: "pending"} = row <-
               locked(scope, company_id, request_id) || {:error, :not_found},
             {:ok, assessment} <- Assessments.write(actor, company_id, input) do
          updated =
            row
            |> Ecto.Changeset.change(
              status: "performed",
              performed_by_user_id: actor.id,
              performed_at: Assessments.now(),
              assessment_id: assessment.id
            )
            |> Repo.update!()

          {:ok, %{request: view(updated), assessment: assessment}}
        else
          %ReassessmentRequest{} -> {:error, :not_pending}
          error -> error
        end
      end)
    else
      %ReassessmentRequest{} -> {:error, :not_pending}
      error -> error
    end
  end

  def perform(_actor, _company_id, _request_id, _attrs), do: {:error, :invalid_assessment}

  defp scored?(scope, company_id, employee_id, skill_id),
    do:
      Repo.exists?(
        from(s in Tenancy.scope_query(Score, scope),
          where:
            s.company_id == ^company_id and s.employee_id == ^employee_id and
              s.skill_id == ^skill_id
        )
      ) and
        Repo.exists?(
          from(s in Tenancy.scope_query(Skill, scope),
            where: s.company_id == ^company_id and s.id == ^skill_id and s.active
          )
        )

  defp not_open(scope, company_id, employee_id, skill_id),
    do:
      if(open?(scope, company_id, employee_id, skill_id), do: {:error, :already_open}, else: :ok)

  defp open?(scope, company_id, employee_id, skill_id),
    do:
      Repo.exists?(
        from(r in Tenancy.scope_query(ReassessmentRequest, scope),
          where:
            r.company_id == ^company_id and r.employee_id == ^employee_id and
              r.skill_id == ^skill_id and r.status == "pending",
          lock: "FOR UPDATE"
        )
      )

  defp get(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(ReassessmentRequest, scope),
          where: r.company_id == ^company_id and r.id == ^id
        )
      )

  defp locked(scope, company_id, id) do
    with {:ok, id} <- Assessments.integer(id),
         %ReassessmentRequest{} = row <-
           Repo.one(
             from(r in Tenancy.scope_query(ReassessmentRequest, scope),
               where: r.company_id == ^company_id and r.id == ^id,
               lock: "FOR UPDATE"
             )
           ) do
      row
    else
      _ -> nil
    end
  end

  defp view(row),
    do:
      Map.take(row, [
        :id,
        :employee_id,
        :skill_id,
        :reason,
        :requested_by_user_id,
        :due_on,
        :status,
        :performed_by_user_id,
        :performed_at,
        :assessment_id,
        :cancelled_at
      ])
end
