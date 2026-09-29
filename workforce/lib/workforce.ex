defmodule Bilimbi.People.Workforce do
  @moduledoc """
  Native read-only workforce boundary for People consumers.

  Every read requires a validated tenant scope and an explicit platform company
  ID. Native workforce company identity currently maps to the same Core Company,
  but both axes remain separate in the returned values. Employee identity never
  implies a login actor. Which Core Employee statuses count as working staff is
  a per-company Base Setting.
  """

  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Company, as: WorkforceCompany
  alias Bilimbi.People.Workforce.Employee, as: WorkforceEmployee
  alias Bilimbi.People.Workforce.Reference

  @source_id "people/native"
  @working_statuses_key "people.workforce.working_statuses"
  @employee_statuses ~w(pending probation active inactive terminated)

  @spec source_id() :: String.t()
  def source_id, do: @source_id

  @spec employee_statuses() :: [String.t()]
  def employee_statuses, do: @employee_statuses

  @spec working_statuses(Scope.t(), term()) :: {:ok, [String.t()]} | {:error, :not_found}
  def working_statuses(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id) do
      {:ok, company_working_statuses(core_company)}
    end
  end

  @spec put_working_statuses(Scope.t(), term(), term()) ::
          {:ok, [String.t()]}
          | {:error, :not_found | :invalid_statuses | Ecto.Changeset.t()}
  def put_working_statuses(%Scope{} = scope, platform_company_id, statuses) do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, statuses} <- normalize_statuses(statuses) do
      Settings.put(@working_statuses_key, statuses, settings_scope(core_company))
    end
  end

  @spec company(Scope.t(), term()) :: {:ok, WorkforceCompany.t()} | {:error, :not_found}
  def company(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id) do
      {:ok,
       %WorkforceCompany{
         reference: reference(:company, core_company.id),
         platform_company_id: core_company.id,
         workforce_company_id: core_company.id,
         name: core_company.name,
         code: core_company.code
       }}
    end
  end

  @spec employees(Scope.t(), term()) :: {:ok, [WorkforceEmployee.t()]} | {:error, :not_found}
  def employees(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, employees} <- Employee.list_employees(scope, core_company.id) do
      statuses = company_working_statuses(core_company)
      visible = Enum.filter(employees, &available_employee?(&1, statuses))
      visible_ids = MapSet.new(visible, & &1.id)

      values =
        Enum.map(visible, fn employee ->
          supervisor_reference =
            if MapSet.member?(visible_ids, employee.supervisor_id),
              do: reference(:employee, employee.supervisor_id),
              else: nil

          project_employee(employee, supervisor_reference)
        end)

      {:ok, values}
    else
      {:error, :company_not_found} -> {:error, :not_found}
      other -> other
    end
  end

  @spec employee(Scope.t(), term(), term()) ::
          {:ok, WorkforceEmployee.t()} | {:error, :not_found}
  def employee(%Scope{} = scope, platform_company_id, employee_id)
      when is_integer(employee_id) and employee_id > 0 do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, core_employee} <- Employee.get_employee(scope, core_company.id, employee_id),
         statuses = company_working_statuses(core_company),
         true <- available_employee?(core_employee, statuses) do
      supervisor_reference =
        visible_supervisor_reference(
          scope,
          core_company.id,
          core_employee.supervisor_id,
          statuses
        )

      {:ok, project_employee(core_employee, supervisor_reference)}
    else
      _ -> {:error, :not_found}
    end
  end

  def employee(%Scope{}, _platform_company_id, _employee_id), do: {:error, :not_found}

  defp live_company(scope, id) do
    with {:ok, company} <- Company.get_company(scope, id),
         true <- company.status == "active" do
      {:ok, company}
    else
      _ -> {:error, :not_found}
    end
  end

  defp company_working_statuses(core_company),
    do: Settings.get(@working_statuses_key, settings_scope(core_company))

  defp settings_scope(core_company),
    do: SettingsScope.company(core_company.id, core_company.tenant_id)

  defp normalize_statuses(statuses) when is_list(statuses) and statuses != [] do
    if Enum.all?(statuses, &(&1 in @employee_statuses)),
      do: {:ok, Enum.filter(@employee_statuses, &(&1 in statuses))},
      else: {:error, :invalid_statuses}
  end

  defp normalize_statuses(_statuses), do: {:error, :invalid_statuses}

  defp available_employee?(employee, statuses),
    do: employee.status in statuses and employee.employee_type != "agent"

  defp project_employee(employee, supervisor_reference) do
    %WorkforceEmployee{
      reference: reference(:employee, employee.id),
      company_reference: reference(:company, employee.company_id),
      platform_company_id: employee.company_id,
      workforce_company_id: employee.company_id,
      employee_number: employee.employee_number,
      display_name: employee.full_name,
      email: employee.email,
      supervisor_reference: supervisor_reference
    }
  end

  defp visible_supervisor_reference(_scope, _company_id, nil, _statuses), do: nil

  defp visible_supervisor_reference(scope, company_id, supervisor_id, statuses) do
    case Employee.get_employee(scope, company_id, supervisor_id) do
      {:ok, supervisor} ->
        if available_employee?(supervisor, statuses),
          do: reference(:employee, supervisor.id),
          else: nil

      _ ->
        nil
    end
  end

  defp reference(type, id),
    do: %Reference{source_id: @source_id, type: type, stable_id: Integer.to_string(id)}
end
