defmodule Bilimbi.People.Workforce.Employments do
  @moduledoc false

  # People's employment records and their transition from Core Employee.
  #
  # A record is claimed from a legacy Core Employee row through Core's public
  # API and keeps that row's ID as the explicit mapping. While Core still
  # carries the HR columns as a compatibility mirror, every People write goes
  # through `Employee.update_employee/4` first and then stores Core's result,
  # so the two never differ because of People. A difference therefore means
  # Core's deprecated HR path wrote after the claim: reads resolve to Core's
  # newer values and the next reconcile adopts them.
  #
  # Every write holds the company lock from `Company.lock_writable_company/2`
  # before Core's own locks and People's record, the order Core Employee uses.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Employment
  alias Bilimbi.People.Workforce.EmploymentRecord
  alias Ecto.Changeset

  @core_fields %{
    employee_number: :employee_number,
    employment_type: :employee_type,
    status: :status,
    employment_start: :employment_start,
    employment_end: :employment_end
  }

  @doc "Claimed records for the legacy employee IDs, keyed by ID."
  def records(scope, employee_ids, opts \\ [])
  def records(_scope, [], _opts), do: %{}

  def records(%Scope{} = scope, employee_ids, opts) do
    query =
      from(record in Tenancy.scope_query(EmploymentRecord, scope),
        where: record.legacy_employee_id in ^employee_ids
      )

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query

    query |> Repo.all() |> Map.new(&{&1.legacy_employee_id, &1})
  end

  @doc "The employment facts for one Core Employee summary and its People record, if claimed."
  def resolve(core, nil), do: employment(core, legacy_facts(core), nil, :core_legacy)

  def resolve(core, %EmploymentRecord{} = record) do
    if in_step?(record, core),
      do: employment(core, record_facts(record), record, :people),
      else: employment(core, legacy_facts(core), record, :legacy_drift)
  end

  @doc "Reads one employee's employment, with the Core person mapping for an unclaimed row."
  def get(%Scope{} = scope, company_id, employee_id) do
    with {:ok, core} <- Employee.get_employee(scope, company_id, employee_id) do
      case records(scope, [employee_id]) do
        %{^employee_id => record} ->
          {:ok, resolve(core, record)}

        _unclaimed ->
          employment = resolve(core, nil)

          case identity(scope, core) do
            {:ok, identity} ->
              {:ok,
               %{
                 employment
                 | person_id: identity.person_id,
                   affiliation_id: identity.affiliation_id
               }}

            _unmapped_or_forbidden ->
              {:ok, employment}
          end
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Counts the company's employees by where their employment facts come from."
  def summary(%Scope{} = scope, company_id) do
    case Employee.list_employees(scope, company_id) do
      {:ok, employees} ->
        records = records(scope, Enum.map(employees, & &1.id))

        counts =
          Enum.reduce(
            employees,
            %{total: 0, people: 0, legacy_drift: 0, core_legacy: 0},
            fn core, counts ->
              %Employment{source: source} = resolve(core, Map.get(records, core.id))
              counts |> Map.update!(:total, &(&1 + 1)) |> Map.update!(source, &(&1 + 1))
            end
          )

        {:ok, counts}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @doc """
  Claims every Core Employee row of a writable company that People does not
  hold yet, and adopts Core's values for claimed rows that drifted.

  Idempotent. Agents and every status are claimed. A row Core has no person
  mapping for, or whose facts are incomplete, stays Core-only and is reported.
  """
  def reconcile(%Scope{} = scope, company_id) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Company.lock_writable_company(scope, company_id),
           {:ok, employees} <- Employee.list_employees(scope, company_id) do
        records = records(scope, Enum.map(employees, & &1.id), lock: true)
        now = now()

        report = %{claimed: 0, adopted: 0, unchanged: 0, unclaimed: []}

        employees
        |> Enum.reduce(report, fn core, report ->
          case reconcile_one(scope, core, Map.get(records, core.id), now) do
            outcome when outcome in [:claimed, :adopted, :unchanged] ->
              Map.update!(report, outcome, &(&1 + 1))

            {:unclaimed, reason} ->
              Map.update!(report, :unclaimed, &[{core.id, reason} | &1])
          end
        end)
        |> Map.update!(:unclaimed, &Enum.reverse/1)
      else
        {:error, reason} -> Repo.rollback(refusal(reason))
      end
    end)
  end

  @doc """
  Changes People's employment facts and writes them through to Core's
  compatibility columns in the same transaction.
  """
  def update(%Scope{} = scope, company_id, employee_id, attrs) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Company.lock_writable_company(scope, company_id),
           {:ok, core} <- Employee.get_employee(scope, company_id, employee_id) do
        record = scope |> records([employee_id], lock: true) |> Map.get(employee_id)
        current = resolve(core, record)

        changeset =
          EmploymentRecord
          |> struct(Map.take(Map.from_struct(current), EmploymentRecord.facts()))
          |> EmploymentRecord.update_changeset(attrs)

        with {:ok, changes} <- valid_changes(changeset),
             {:ok, core} <- write_core(scope, core, changes, changeset),
             {:ok, record} <- store(scope, core, record) do
          resolve(core, record)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(refusal(reason))
      end
    end)
  end

  defp reconcile_one(scope, core, nil, now) do
    case identity(scope, core) do
      {:ok, identity} ->
        case insert(scope, core, identity, now) do
          {:ok, _record} -> :claimed
          {:error, _changeset} -> {:unclaimed, :invalid_facts}
        end

      :error ->
        {:unclaimed, :no_person_mapping}

      {:error, :forbidden} ->
        Repo.rollback(:unauthorized)
    end
  end

  defp reconcile_one(_scope, core, record, _now) do
    if in_step?(record, core) do
      :unchanged
    else
      record |> Changeset.change(legacy_facts(core)) |> Repo.update!()
      :adopted
    end
  end

  defp valid_changes(%Changeset{valid?: true, changes: changes}), do: {:ok, changes}
  defp valid_changes(%Changeset{} = changeset), do: {:error, %{changeset | action: :update}}

  defp write_core(_scope, core, changes, _changeset) when map_size(changes) == 0, do: {:ok, core}

  defp write_core(scope, core, changes, changeset) do
    attrs = Map.new(changes, fn {field, value} -> {Map.fetch!(@core_fields, field), value} end)

    case Employee.update_employee(scope, core.company_id, core.id, attrs) do
      {:ok, core} -> {:ok, core}
      {:error, %Changeset{} = core_changeset} -> {:error, core_errors(changeset, core_changeset)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # Core reports its own field names; a People caller reads People's.
  defp core_errors(changeset, core_changeset) do
    people_fields = Map.new(@core_fields, fn {people, core} -> {core, people} end)

    core_changeset.errors
    |> Enum.reduce(changeset, fn {field, {message, keys}}, acc ->
      Changeset.add_error(acc, Map.get(people_fields, field, :base), message, keys)
    end)
    |> Map.put(:action, :update)
  end

  defp store(scope, core, nil) do
    case identity(scope, core) do
      {:ok, identity} ->
        case insert(scope, core, identity, now()) do
          {:ok, record} -> {:ok, record}
          {:error, changeset} -> {:error, changeset}
        end

      :error ->
        {:error, :no_person_mapping}

      {:error, :forbidden} ->
        {:error, :unauthorized}
    end
  end

  defp store(_scope, core, record) do
    {:ok, record |> Changeset.change(legacy_facts(core)) |> Repo.update!()}
  end

  defp insert(scope, core, identity, now) do
    %EmploymentRecord{}
    |> EmploymentRecord.claim_changeset(
      Map.merge(legacy_facts(core), %{
        tenant_id: Scope.tenant_id(scope),
        company_id: identity.company_id,
        legacy_employee_id: core.id,
        person_id: identity.person_id,
        affiliation_id: identity.affiliation_id,
        legacy_created_at: core.created_at,
        claimed_at: now
      })
    )
    |> Repo.insert()
  end

  # The employer is the affiliation's company, which must be the employee's.
  # Core reveals the mapping only to an actor who may view contacts, so a
  # People operator needs that grant too; it is refused, not reported missing.
  defp identity(scope, core) do
    case Employee.person_identity(scope, core.id) do
      {:ok, %{company_id: company_id} = identity} when company_id == core.company_id ->
        {:ok, identity}

      {:error, :forbidden} ->
        {:error, :forbidden}

      _ ->
        :error
    end
  end

  defp employment(core, facts, record, source) do
    struct!(
      Employment,
      Map.merge(facts, %{
        employee_id: core.id,
        platform_company_id: core.company_id,
        person_id: record && record.person_id,
        affiliation_id: record && record.affiliation_id,
        source: source
      })
    )
  end

  defp in_step?(record, core), do: record_facts(record) == legacy_facts(core)

  defp record_facts(record), do: Map.take(record, [:metadata | EmploymentRecord.facts()])

  defp legacy_facts(core) do
    @core_fields
    |> Map.new(fn {field, core_field} -> {field, Map.fetch!(core, core_field)} end)
    |> Map.put(:metadata, core.metadata)
  end

  defp refusal(:company_not_found), do: :not_found
  defp refusal(:employee_not_found), do: :not_found
  defp refusal(reason), do: reason

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
