defmodule Bilimbi.People.Skills.Access do
  @moduledoc false
  # Company, employee, login-actor and reporting-line resolution shared by the
  # assessment, reassessment, action and reminder workflows.

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.Actor
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.User
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @max_depth 12

  def current_company(scope, company_id) do
    with {:ok, read} <- Workforce.company(scope, company_id),
         do: ReadResult.require_current(read)
  end

  def current_employee(scope, company_id, employee_id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, employee_id),
         do: ReadResult.require_current(read)
  end

  def current_employees(scope, company_id) do
    with {:ok, read} <- Workforce.employees(scope, company_id),
         do: ReadResult.require_current(read)
  end

  def employees_by_ids(_scope, _company_id, []), do: {:ok, []}

  def employees_by_ids(scope, company_id, ids) do
    with {:ok, read} <- Workforce.employees_by_ids(scope, company_id, ids),
         do: ReadResult.require_current(read)
  end

  def names(scope, company_id, ids) do
    with {:ok, employees} <- employees_by_ids(scope, company_id, Enum.uniq(ids)) do
      {:ok,
       Map.new(employees, fn employee ->
         {employee_id(employee), "#{employee.display_name} (#{employee.employee_number})"}
       end)}
    end
  end

  def settings_scope(scope, company),
    do: SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

  def employee_id(employee), do: String.to_integer(employee.reference.stable_id)

  @doc "Authorizes a login actor for one company and returns the live workforce company."
  def authorize(%Actor{type: :user} = actor, company_id, capability) do
    with {:ok, _company} <- Company.authorize_company_target(actor.scope, company_id, capability),
         do: current_company(actor.scope, company_id)
  end

  def authorize(%Actor{}, _company_id, _capability), do: {:error, :unauthorized}

  @doc "Authorizes an actor holding at least one of the capabilities."
  def authorize_any(actor, company_id, capabilities) do
    case Enum.find(capabilities, &allowed?(actor, company_id, &1)) do
      nil -> authorize(actor, company_id, hd(capabilities))
      capability -> authorize(actor, company_id, capability)
    end
  end

  def allowed?(%Actor{type: :user} = actor, company_id, capability),
    do: match?({:ok, _}, Company.authorize_company_target(actor.scope, company_id, capability))

  def allowed?(_actor, _company_id, _capability), do: false

  @doc "The employee linked to a user actor signed in to this company, whatever their status."
  def linked_employee_id(scope, company_id, %Actor{type: :user, company_id: company_id, id: id}) do
    with {:ok, user} <- User.get_user(scope, company_id, id),
         employee_id when is_integer(employee_id) <- user.employee_id do
      {:ok, employee_id}
    else
      _ -> :none
    end
  end

  def linked_employee_id(_scope, _company_id, _actor), do: :none

  @doc """
  The working employee linked to a user actor signed in to this company,
  resolved through Core User and the workforce seam on every call, never
  cached by a page.
  """
  def self_employee(scope, company_id, actor) do
    with {:ok, employee_id} <- linked_employee_id(scope, company_id, actor),
         {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      {:ok, employee_id}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  The people an actor may act on. A holder of the company-wide capability
  reaches everyone; any other actor reaches only the people who report to
  them, directly or through others, in the workforce supervisor chain. An
  actor with no working linked employee reaches nobody.
  """
  def reach(%Actor{} = actor, company_id, wide_capability) do
    if allowed?(actor, company_id, wide_capability) do
      {:ok, :company}
    else
      case linked_employee_id(actor.scope, company_id, actor) do
        {:ok, employee_id} ->
          with {:ok, team} <- team(actor.scope, company_id, employee_id),
               do: {:ok, {:team, team}}

        :none ->
          {:ok, {:team, MapSet.new()}}
      end
    end
  end

  def within?(:company, _employee_id), do: true
  def within?({:team, team}, employee_id), do: MapSet.member?(team, employee_id)

  @doc "Everyone below an employee in the supervisor chain, excluding the employee."
  def team(scope, company_id, manager_id) do
    with {:ok, employees} <- current_employees(scope, company_id) do
      reports =
        Enum.group_by(
          for(e <- employees, e.supervisor_reference != nil, do: e),
          &String.to_integer(&1.supervisor_reference.stable_id),
          &employee_id/1
        )

      if Enum.any?(employees, &(employee_id(&1) == manager_id)),
        do: {:ok, descend(reports, [manager_id], MapSet.new([manager_id]), MapSet.new(), 0)},
        else: {:ok, MapSet.new()}
    end
  end

  @doc "The direct supervisor of an employee, if the workforce names one."
  def supervisor_id(employee) do
    if employee.supervisor_reference,
      do: String.to_integer(employee.supervisor_reference.stable_id)
  end

  defp descend(_reports, [], _seen, found, _depth), do: found
  defp descend(_reports, _frontier, _seen, found, depth) when depth >= @max_depth, do: found

  defp descend(reports, frontier, seen, found, depth) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(reports, &1, []))
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    descend(
      reports,
      next,
      Enum.into(next, seen),
      Enum.into(next, found),
      depth + 1
    )
  end

  @doc "User IDs of a company's users who hold a capability."
  def capability_holders(scope, company_id, capability) do
    with {:ok, users} <- User.list_company_users(scope, company_id) do
      for user <- users,
          actor = Authz.actor(:user, user.id, scope, company_id),
          capability in Authz.effective_capabilities(actor).allowed,
          do: user.id
    else
      _ -> []
    end
  end

  @doc "The user linked to each employee of the company, by employee ID."
  def users_by_employee(scope, company_id) do
    case User.list_company_users(scope, company_id) do
      {:ok, users} ->
        for user <- users, user.employee_id != nil, into: %{}, do: {user.employee_id, user.id}

      _ ->
        %{}
    end
  end

  def transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def user_id(%Actor{type: :user, id: id}), do: id
end
