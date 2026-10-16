defmodule Bilimbi.People.Workforce do
  @moduledoc """
  Native read-only workforce boundary for People consumers.

  Every read requires a validated tenant scope and an explicit platform company
  ID. Native workforce company identity currently maps to the same Core Company,
  but both axes remain separate in the returned values. Employee identity never
  implies a login actor. Which employment statuses count as working staff is
  a per-company Base Setting.

  People owns employment numbers, types, statuses and dates: a claimed
  employment record references the Core Person and affiliation and keeps the
  legacy Core Employee ID as its explicit mapping. See `docs/README.md` for the
  transition from Core's compatibility columns.
  """

  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce.Company, as: WorkforceCompany
  alias Bilimbi.People.Workforce.Employee, as: WorkforceEmployee
  alias Bilimbi.People.Workforce.Employment
  alias Bilimbi.People.Workforce.Employments
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Workforce.Reference

  @position_reader_key {__MODULE__, :position_reader}

  @source_id "people/native"
  @working_statuses_key "people.workforce.working_statuses"
  @settings_capability "people.workforce.settings.manage"
  @employment_view_capability "people.workforce.employment.view"
  @employment_manage_capability "people.workforce.employment.manage"
  @employee_statuses ~w(pending probation active inactive terminated)
  @lookup_limit 1_000

  @spec source_id() :: String.t()
  def source_id, do: @source_id

  @doc "Returns whether a position reader is currently registered."
  @spec positions_available?() :: boolean()
  def positions_available?, do: :persistent_term.get(@position_reader_key, nil) != nil

  @doc "Registers the mounted position owner at application startup."
  def register_position_reader(module) when is_atom(module) do
    :persistent_term.put(@position_reader_key, module)
    :ok
  end

  @doc "Removes a position owner when its application stops."
  def unregister_position_reader(module) do
    if :persistent_term.get(@position_reader_key, nil) == module,
      do: :persistent_term.erase(@position_reader_key)

    :ok
  end

  @doc """
  Reads a bounded page of native positions when Organisation is mounted.

  Pass `cursor: nil` to start a high-water ID scan. The read value contains
  `positions`, `next_cursor`, and `high_water_id`; resume with `cursor: next_cursor`
  until it is nil. Only reconcile absent IDs at or below the watermark after
  completing every page. See `workforce/docs/README.md` for mutation semantics.
  Without `cursor:`, existing list-valued offset pages remain supported.
  """
  def positions(%Scope{} = scope, platform_company_id, as_of \\ Date.utc_today(), options \\ []) do
    with {:ok, _company} <- live_company(scope, platform_company_id) do
      case :persistent_term.get(@position_reader_key, nil) do
        nil -> {:error, :unavailable}
        reader -> current(reader.positions(scope, platform_company_id, as_of, options))
      end
    end
  end

  @spec employee_statuses() :: [String.t()]
  def employee_statuses, do: @employee_statuses

  @spec working_statuses(Scope.t(), term()) ::
          {:ok, ReadResult.t()} | {:error, :not_found}
  def working_statuses(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id) do
      {:ok, ReadResult.current(company_working_statuses(core_company))}
    end
  end

  @doc "Replaces the company's working statuses; the scope's actor must hold the settings capability now."
  @spec put_working_statuses(Scope.t(), term(), term()) ::
          {:ok, [String.t()]}
          | {:error, :unauthorized | :not_found | :invalid_statuses | Ecto.Changeset.t()}
  def put_working_statuses(%Scope{} = scope, platform_company_id, statuses) do
    with {:ok, _actor} <-
           Authorization.authorize(scope, platform_company_id, @settings_capability),
         {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, statuses} <- normalize_statuses(statuses) do
      Settings.put(@working_statuses_key, statuses, settings_scope(core_company))
    end
  end

  @spec company(Scope.t(), term()) :: {:ok, ReadResult.t()} | {:error, :not_found}
  def company(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id) do
      {:ok,
       ReadResult.current(%WorkforceCompany{
         reference: reference(:company, core_company.id),
         platform_company_id: core_company.id,
         workforce_company_id: core_company.id,
         name: core_company.name,
         code: core_company.code
       })}
    end
  end

  @spec employees(Scope.t(), term()) :: {:ok, ReadResult.t()} | {:error, :not_found}
  def employees(%Scope{} = scope, platform_company_id) do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, employees} <- Employee.list_employees(scope, core_company.id) do
      statuses = company_working_statuses(core_company)

      visible =
        scope |> with_employments(employees) |> Enum.filter(&available_employee?(&1, statuses))

      visible_ids = MapSet.new(visible, fn {employee, _employment} -> employee.id end)

      values =
        Enum.map(visible, fn {employee, _employment} = pair ->
          supervisor_reference =
            if MapSet.member?(visible_ids, employee.supervisor_id),
              do: reference(:employee, employee.supervisor_id),
              else: nil

          project_employee(pair, supervisor_reference)
        end)

      {:ok, ReadResult.current(values)}
    else
      {:error, :company_not_found} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Returns the exposed employees among at most 1,000 IDs, without reading the workforce."
  @spec employees_by_ids(Scope.t(), term(), term()) ::
          {:ok, ReadResult.t()} | {:error, :not_found | :invalid_options}
  def employees_by_ids(%Scope{} = scope, platform_company_id, employee_ids) do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, ids} <- lookup_ids(employee_ids) do
      statuses = company_working_statuses(core_company)
      visible = available_employees(scope, core_company.id, ids, statuses)

      supervisor_ids =
        visible
        |> Enum.map(fn {employee, _employment} -> employee.supervisor_id end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      visible_supervisors =
        scope
        |> available_employees(core_company.id, supervisor_ids, statuses)
        |> MapSet.new(fn {employee, _employment} -> employee.id end)

      values =
        Enum.map(visible, fn {employee, _employment} = pair ->
          supervisor_reference =
            if MapSet.member?(visible_supervisors, employee.supervisor_id),
              do: reference(:employee, employee.supervisor_id),
              else: nil

          project_employee(pair, supervisor_reference)
        end)

      {:ok, ReadResult.current(values)}
    end
  end

  @spec employee(Scope.t(), term(), term()) ::
          {:ok, ReadResult.t()} | {:error, :not_found}
  def employee(%Scope{} = scope, platform_company_id, employee_id)
      when is_integer(employee_id) and employee_id > 0 do
    with {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, core_employee} <- Employee.get_employee(scope, core_company.id, employee_id),
         statuses = company_working_statuses(core_company),
         [pair] <- with_employments(scope, [core_employee]),
         true <- available_employee?(pair, statuses) do
      supervisor_reference =
        visible_supervisor_reference(
          scope,
          core_company.id,
          core_employee.supervisor_id,
          statuses
        )

      {:ok, ReadResult.current(project_employee(pair, supervisor_reference))}
    else
      _ -> {:error, :not_found}
    end
  end

  def employee(%Scope{}, _platform_company_id, _employee_id), do: {:error, :not_found}

  @doc """
  Reads one employee's employment facts: number, type, status, dates and HR
  metadata, with the Core person and affiliation it references.

  Private HR facts, so the scope's actor must hold
  `people.workforce.employment.view` now. Every status and agent rows are
  readable here, unlike the working-staff reads above. An unclaimed row's
  person and affiliation come from Core and are nil unless the actor may also
  view Core contacts.
  """
  @spec employment(Scope.t(), term(), term()) ::
          {:ok, ReadResult.t()} | {:error, :unauthorized | :not_found}
  def employment(%Scope{} = scope, platform_company_id, employee_id) do
    with {:ok, _actor} <-
           Authorization.authorize(scope, platform_company_id, @employment_view_capability),
         {:ok, core_company} <- live_company(scope, platform_company_id),
         true <- is_integer(employee_id) and employee_id > 0,
         {:ok, %Employment{} = employment} <-
           Employments.get(scope, core_company.id, employee_id) do
      {:ok, ReadResult.current(employment)}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Counts the company's employees by where their employment facts come from:
  `:people` (claimed and in step), `:legacy_drift` (claimed, then changed
  through Core's deprecated HR path) and `:core_legacy` (not claimed yet).
  Requires `people.workforce.employment.view`.
  """
  @spec employment_summary(Scope.t(), term()) ::
          {:ok, ReadResult.t()} | {:error, :unauthorized | :not_found}
  def employment_summary(%Scope{} = scope, platform_company_id) do
    with {:ok, _actor} <-
           Authorization.authorize(scope, platform_company_id, @employment_view_capability),
         {:ok, core_company} <- live_company(scope, platform_company_id),
         {:ok, counts} <- Employments.summary(scope, core_company.id) do
      {:ok, ReadResult.current(counts)}
    end
  end

  @doc """
  Claims the company's legacy Core Employee HR rows into People and adopts
  Core's values for claimed rows that drifted. Idempotent.

  Requires `people.workforce.employment.manage` now, and Core's
  `admin.person.view`, which Core requires before it reveals the person
  mapping a claim records. Returns counts of `claimed`, `adopted` and
  `unchanged` rows and the `unclaimed` employee IDs with a reason
  (`:no_person_mapping` or `:invalid_facts`); those stay Core-only and
  unchanged. An archived company is `:company_archived`.
  """
  @spec reconcile_employments(Scope.t(), term()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found | :company_archived}
  def reconcile_employments(%Scope{} = scope, platform_company_id) do
    with {:ok, _actor} <-
           Authorization.authorize(scope, platform_company_id, @employment_manage_capability),
         {:ok, core_company} <- live_company(scope, platform_company_id) do
      Employments.reconcile(scope, core_company.id)
    end
  end

  @doc """
  Changes an employee's number, type, status or dates in People.

  Requires `people.workforce.employment.manage` now. The change is written
  through to Core Employee's compatibility columns in the same transaction, so
  `core.employee.*` callers keep reading current values, and an unclaimed
  employee is claimed by the write, which needs Core's `admin.person.view`
  as `reconcile_employments/2` does. Accepts `employee_number`,
  `employment_type`, `status`, `employment_start` and `employment_end`;
  invalid values, and values Core refuses, return a changeset keyed by those
  names.
  """
  @spec update_employment(Scope.t(), term(), term(), map()) ::
          {:ok, Employment.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :company_archived
             | :no_person_mapping
             | Ecto.Changeset.t()}
  def update_employment(%Scope{} = scope, platform_company_id, employee_id, attrs)
      when is_integer(employee_id) and employee_id > 0 and is_map(attrs) do
    with {:ok, _actor} <-
           Authorization.authorize(scope, platform_company_id, @employment_manage_capability),
         {:ok, core_company} <- live_company(scope, platform_company_id) do
      Employments.update(scope, core_company.id, employee_id, attrs)
    end
  end

  def update_employment(%Scope{}, _platform_company_id, _employee_id, _attrs),
    do: {:error, :not_found}

  defp current({:ok, value}), do: {:ok, ReadResult.current(value)}
  defp current(error), do: error

  defp live_company(scope, id) do
    with {:ok, company} <- Company.get_company(scope, id),
         true <- company.status == "active" do
      {:ok, company}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lookup_ids(ids) when is_list(ids) and length(ids) <= @lookup_limit do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :invalid_options}
  end

  defp lookup_ids(_ids), do: {:error, :invalid_options}

  defp available_employees(_scope, _company_id, [], _statuses), do: []

  defp available_employees(scope, company_id, ids, statuses) do
    {:ok, employees} = Employee.get_tenant_employees(scope, ids)

    employees
    |> Map.values()
    |> Enum.filter(&(&1.company_id == company_id))
    |> Enum.sort_by(& &1.id)
    |> then(&with_employments(scope, &1))
    |> Enum.filter(&available_employee?(&1, statuses))
  end

  # Pairs each Core Employee with its People employment facts in one query.
  defp with_employments(scope, employees) do
    records = Employments.records(scope, Enum.map(employees, & &1.id))
    Enum.map(employees, &{&1, Employments.resolve(&1, Map.get(records, &1.id))})
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

  defp available_employee?({_employee, employment}, statuses),
    do: employment.status in statuses and employment.employment_type != "agent"

  defp project_employee({employee, employment}, supervisor_reference) do
    %WorkforceEmployee{
      reference: reference(:employee, employee.id),
      company_reference: reference(:company, employee.company_id),
      platform_company_id: employee.company_id,
      workforce_company_id: employee.company_id,
      employee_number: employment.employee_number,
      display_name: employee.full_name,
      email: employee.email,
      supervisor_reference: supervisor_reference
    }
  end

  defp visible_supervisor_reference(_scope, _company_id, nil, _statuses), do: nil

  defp visible_supervisor_reference(scope, company_id, supervisor_id, statuses) do
    case Employee.get_employee(scope, company_id, supervisor_id) do
      {:ok, supervisor} ->
        [pair] = with_employments(scope, [supervisor])

        if available_employee?(pair, statuses),
          do: reference(:employee, supervisor.id),
          else: nil

      _ ->
        nil
    end
  end

  defp reference(type, id),
    do: %Reference{source_id: @source_id, type: type, stable_id: Integer.to_string(id)}
end
