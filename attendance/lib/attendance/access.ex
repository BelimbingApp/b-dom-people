defmodule Bilimbi.People.Attendance.Access do
  @moduledoc false
  # Company, employee and login-actor resolution shared by attendance workflows.

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.User
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

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

  def settings_scope(scope, company),
    do: SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

  @doc "The working employee linked to a user actor signed in to this company."
  def self_employee(scope, company_id, actor) do
    with {:ok, employee_id} <- linked_employee_id(scope, company_id, actor),
         {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      {:ok, employee_id}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "The employee linked to a user actor, whatever its working status."
  def linked_employee_id(scope, company_id, actor) do
    with %{type: :user, company_id: ^company_id, id: user_id} <- actor,
         {:ok, user} <- User.get_user(scope, company_id, user_id),
         employee_id when is_integer(employee_id) <- user.employee_id do
      {:ok, employee_id}
    else
      _ -> :none
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
end
