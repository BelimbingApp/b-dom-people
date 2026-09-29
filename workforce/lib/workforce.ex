defmodule Bilimbi.People.Workforce do
  @moduledoc """
  Native read-only workforce boundary for People consumers.

  Every read requires a validated tenant scope and an explicit platform company
  ID. Native workforce company identity currently maps to the same Core Company,
  but both axes remain separate in the returned values. Employee identity never
  implies a login actor. Position reads stay unavailable until Organisation
  publishes a position API; Core departments are not positions.
  """

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Company, as: WorkforceCompany
  alias Bilimbi.People.Workforce.Employee, as: WorkforceEmployee
  alias Bilimbi.People.Workforce.Reference
  alias Bilimbi.People.Workforce.Snapshot

  @source_id "people/native"

  @spec source_id() :: String.t()
  def source_id, do: @source_id

  @spec company(Scope.t(), term()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def company(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id) do
      value = %WorkforceCompany{
        reference: reference(:company, core_company.id),
        platform_company_id: core_company.id,
        workforce_company_id: core_company.id,
        name: core_company.name,
        code: core_company.code
      }

      {:ok, Snapshot.current(@source_id, value)}
    end
  end

  @spec employees(Scope.t(), term()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def employees(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, employees} <- Employee.list_employees(scope, core_company.id) do
      visible = Enum.filter(employees, &available_employee?/1)
      visible_ids = MapSet.new(visible, & &1.id)

      values =
        Enum.map(visible, fn employee ->
          supervisor_reference =
            if MapSet.member?(visible_ids, employee.supervisor_id),
              do: reference(:employee, employee.supervisor_id),
              else: nil

          project_employee(employee, supervisor_reference)
        end)

      {:ok, Snapshot.current(@source_id, values)}
    else
      {:error, :company_not_found} -> {:error, :not_found}
      other -> other
    end
  end

  @spec employee(Scope.t(), term(), term()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def employee(%Scope{} = scope, platform_company_id, employee_id)
      when is_integer(employee_id) and employee_id > 0 do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, core_employee} <- Employee.get_employee(scope, core_company.id, employee_id),
         true <- available_employee?(core_employee) do
      supervisor_reference =
        visible_supervisor_reference(scope, core_company.id, core_employee.supervisor_id)

      {:ok, Snapshot.current(@source_id, project_employee(core_employee, supervisor_reference))}
    else
      _ -> {:error, :not_found}
    end
  end

  def employee(%Scope{}, _platform_company_id, _employee_id), do: {:error, :not_found}

  @spec positions(Scope.t(), term()) :: {:error, :not_found | :unavailable}
  def positions(%Scope{} = scope, platform_company_id) do
    with {:ok, _company} <- live_company(scope, platform_company_id) do
      {:error, :unavailable}
    end
  end

  defp live_company(scope, id) do
    with {:ok, company} <- Company.get_company(scope, id),
         true <- company.status == "active" do
      {:ok, company}
    else
      _ -> {:error, :not_found}
    end
  end

  defp available_employee?(employee),
    do: employee.status == "active" and employee.employee_type != "agent"

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

  defp visible_supervisor_reference(_scope, _company_id, nil), do: nil

  defp visible_supervisor_reference(scope, company_id, supervisor_id) do
    case Employee.get_employee(scope, company_id, supervisor_id) do
      {:ok, supervisor} ->
        if available_employee?(supervisor),
          do: reference(:employee, supervisor.id),
          else: nil

      _ ->
        nil
    end
  end

  defp reference(type, id),
    do: %Reference{source_id: @source_id, type: type, stable_id: Integer.to_string(id)}
end
