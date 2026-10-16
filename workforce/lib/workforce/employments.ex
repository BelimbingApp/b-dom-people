defmodule Bilimbi.People.Workforce.Employments do
  @moduledoc false

  # People's employment records and their transition from Core Employee.
  #
  # A record is claimed from a legacy Core Employee row through Core's public
  # API and keeps that row's ID as the explicit mapping. People is the writer:
  # `update/4` stores the change in People first and mirrors it to Core's
  # deprecated compatibility columns in the same transaction. Until Core
  # routes its own HR writes to `EmploymentOwner`, Core's deprecated path can
  # still write afterwards; reads then resolve to Core's newer values
  # (`:legacy_drift`) and the next reconcile adopts them. Once the owner is
  # registered, a record is always read as People's.
  #
  # Every write holds the company lock from `Company.lock_writable_company/2`
  # before Core's own locks and People's record, the order Core Employee uses.

  import Ecto.Query

  require Logger

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Employment
  alias Bilimbi.People.Workforce.EmploymentException
  alias Bilimbi.People.Workforce.EmploymentOwner
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
    if EmploymentOwner.registered?() or in_step?(record, core),
      do: employment(core, record_facts(record), record, :people),
      else: employment(core, legacy_facts(core), record, :legacy_drift)
  end

  @doc "A Core Employee summary carrying the employment facts People resolves for it."
  def overlay(core, record) do
    employment = resolve(core, record)

    %{
      core
      | employee_number: employment.employee_number,
        employee_type: employment.employment_type,
        status: employment.status,
        employment_start: employment.employment_start,
        employment_end: employment.employment_end,
        metadata: employment.metadata
    }
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
  mapping for, whose facts are incomplete, or whose affiliation another record
  already holds stays Core-only and is recorded as an exception.
  """
  def reconcile(%Scope{} = scope, company_id) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Company.lock_writable_company(scope, company_id),
           {:ok, employees} <- Employee.list_employees(scope, company_id) do
        records = records(scope, Enum.map(employees, & &1.id), lock: true)
        now = now()

        # A company without employees has nothing to claim, and `exceptions/2`
        # already hides rows of employees that are gone.
        if employees != [], do: clear_exceptions(scope, company_id)
        report = %{claimed: 0, adopted: 0, unchanged: 0, unclaimed: []}

        employees
        |> Enum.reduce(report, fn core, report ->
          case reconcile_one(scope, core, Map.get(records, core.id), now) do
            outcome when outcome in [:claimed, :adopted, :unchanged] ->
              Map.update!(report, outcome, &(&1 + 1))

            {:unclaimed, reason} ->
              record_exception(scope, core, reason, now)
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
  Claims the legacy rows of every live company in every tenant and adopts
  Core's values for rows that drifted, as a system seed and before the owner
  registers. Archived companies are frozen and stay Core-only. A company that
  fails does not stop the others; the failures are returned and the run is
  safe to repeat. What it claimed and adopted is logged.
  """
  def backfill do
    results =
      for tenant <- Tenancy.list_tenants(),
          {:ok, scope} <- [Tenancy.scope(tenant.id)],
          {:ok, companies} <- [Company.list_companies(scope)],
          company <- companies,
          result = reconcile(scope, company.id),
          result != {:error, :company_archived} do
        {company.id, result}
      end

    reports = for {_company_id, {:ok, report}} <- results, do: report
    failures = for {company_id, {:error, reason}} <- results, do: {company_id, reason}

    Logger.info(
      "People employment backfill: claimed #{sum(reports, :claimed)}, " <>
        "adopted #{sum(reports, :adopted)} drifted, " <>
        "unclaimed #{Enum.sum(Enum.map(reports, &length(&1.unclaimed)))}, " <>
        "failed companies #{length(failures)}"
    )

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp sum(reports, key), do: reports |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  @doc """
  Adopts Core's values for claimed rows Core wrote at or after `since`, and
  claims rows Core created since then, as the owner registers. Closes the
  window between the registration-time backfill and Core routing its writes
  to the owner, including writes still in flight at registration. A claimed
  row is adopted only when Core's write is not older than People's record
  (`updated_at`), so a People write made meanwhile is never reverted. A new
  row People cannot claim is recorded as an exception. Returns the number of
  rows adopted or claimed.
  """
  def adopt_written_since(%NaiveDateTime{} = since) do
    results =
      for tenant <- Tenancy.list_tenants(),
          {:ok, scope} <- [Tenancy.scope(tenant.id)],
          {:ok, companies} <- [Company.list_companies(scope)],
          company <- companies do
        adopt_company_since(scope, company.id, since)
      end

    case for({:error, reason} <- results, do: reason) do
      [] -> {:ok, results |> Enum.map(fn {:ok, count} -> count end) |> Enum.sum()}
      failures -> {:error, failures}
    end
  end

  defp at_or_after?(nil, _since), do: false
  defp at_or_after?(time, since), do: NaiveDateTime.compare(time, since) != :lt

  defp adopt_company_since(scope, company_id, since) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Company.lock_writable_company(scope, company_id),
           {:ok, employees} <- Employee.list_employees(scope, company_id) do
        written =
          Enum.filter(
            employees,
            &(at_or_after?(&1.updated_at, since) or at_or_after?(&1.created_at, since))
          )

        records = records(scope, Enum.map(written, & &1.id), lock: true)
        now = now()

        Enum.count(written, fn core ->
          case Map.get(records, core.id) do
            %EmploymentRecord{} = record ->
              if not in_step?(record, core) and at_or_after?(core.updated_at, record.updated_at) do
                record |> Changeset.change(legacy_facts(core)) |> Repo.update!()
                true
              else
                false
              end

            nil ->
              case reconcile_one(scope, core, nil, now) do
                :claimed ->
                  true

                {:unclaimed, reason} ->
                  record_exception(scope, core, reason, now)
                  false
              end
          end
        end)
      else
        {:error, :company_archived} -> 0
        {:error, reason} -> Repo.rollback(refusal(reason))
      end
    end)
  end

  @doc "The company's legacy rows People could not claim, with the reason."
  def exceptions(%Scope{} = scope, company_id) do
    rows =
      Repo.all(
        from(row in Tenancy.scope_query(EmploymentException, scope),
          where: row.company_id == ^company_id,
          order_by: row.legacy_employee_id
        )
      )

    case rows do
      [] ->
        []

      rows ->
        {:ok, employees} =
          Employee.get_tenant_employees(scope, Enum.map(rows, & &1.legacy_employee_id))

        Enum.flat_map(rows, fn row ->
          case Map.get(employees, row.legacy_employee_id) do
            %{company_id: ^company_id} = core ->
              [
                %{
                  employee_id: core.id,
                  employee_number: core.employee_number,
                  full_name: core.full_name,
                  reason: String.to_existing_atom(row.reason),
                  detected_at: row.detected_at
                }
              ]

            _gone_or_moved ->
              []
          end
        end)
    end
  end

  @doc """
  Changes People's employment facts and mirrors them to Core's compatibility
  columns in the same transaction.
  """
  def update(%Scope{} = scope, company_id, employee_id, attrs) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Company.lock_writable_company(scope, company_id),
           {:ok, core} <- Employee.get_employee(scope, company_id, employee_id) do
        record = scope |> records([employee_id], lock: true) |> Map.get(employee_id)
        current = resolve(core, record)

        changeset =
          %EmploymentRecord{}
          |> struct(Map.take(Map.from_struct(current), EmploymentRecord.facts()))
          |> EmploymentRecord.update_changeset(attrs)

        with {:ok, changes} <- valid_changes(changeset),
             {:ok, record} <- store(scope, core, record, current, changes),
             {:ok, core} <- mirror(scope, core, changes, changeset) do
          resolve(core, record)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(refusal(reason))
      end
    end)
  end

  @doc """
  Core's deprecated HR path wrote the row in the caller's transaction: adopt
  its values, or claim the row with the person and affiliation Core read in
  that transaction. Never refuses, so Core's write stands; a row People
  cannot claim is recorded as an exception. Core already authorized the
  write, so this reads no mapping and no capability-gated list.
  """
  def legacy_written(%Scope{} = scope, employee_id, person_id, affiliation_id) do
    with {:ok, core} <- Employee.get_employee(scope, employee_id) do
      case records(scope, [employee_id], lock: true) do
        %{^employee_id => record} ->
          record |> Changeset.change(legacy_facts(core)) |> Repo.update!()
          :ok

        _unclaimed ->
          claim_written(scope, core, person_id, affiliation_id)
      end
    else
      _gone -> :ok
    end
  end

  defp claim_written(scope, core, person_id, affiliation_id)
       when is_integer(person_id) and is_integer(affiliation_id) do
    now = now()

    identity = %{
      company_id: core.company_id,
      person_id: person_id,
      affiliation_id: affiliation_id
    }

    case insert(scope, core, identity, legacy_facts(core), now) do
      {:ok, _record} -> :ok
      {:error, reason} -> record_exception(scope, core, reason, now)
    end
  end

  defp claim_written(scope, core, _person_id, _affiliation_id),
    do: record_exception(scope, core, :no_person_mapping, now())

  defp reconcile_one(scope, core, nil, now) do
    case identity(scope, core) do
      {:ok, identity} ->
        case insert(scope, core, identity, legacy_facts(core), now) do
          {:ok, _record} -> :claimed
          {:error, reason} -> {:unclaimed, reason}
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

  defp mirror(_scope, core, changes, _changeset) when map_size(changes) == 0, do: {:ok, core}

  defp mirror(scope, core, changes, changeset) do
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

  # An unclaimed employee is claimed with the change applied; a claimed one
  # starts from the facts it currently resolves to, so a drifted Core value
  # that the change does not touch is kept.
  defp store(scope, core, nil, _current, changes) do
    case identity(scope, core) do
      {:ok, identity} ->
        insert(scope, core, identity, Map.merge(legacy_facts(core), changes), now())

      :error ->
        {:error, :no_person_mapping}

      {:error, :forbidden} ->
        {:error, :unauthorized}
    end
  end

  defp store(_scope, _core, record, current, changes) do
    facts = current |> Map.take([:metadata | EmploymentRecord.facts()]) |> Map.merge(changes)
    {:ok, record |> Changeset.change(facts) |> Repo.update!()}
  end

  # The insert runs in a savepoint: a unique violation aborts a PostgreSQL
  # transaction, and a conflict must leave the rest of the claim standing.
  defp insert(scope, core, identity, facts, now) do
    changeset =
      EmploymentRecord.claim_changeset(
        %EmploymentRecord{},
        Map.merge(facts, %{
          tenant_id: Scope.tenant_id(scope),
          company_id: identity.company_id,
          legacy_employee_id: core.id,
          person_id: identity.person_id,
          affiliation_id: identity.affiliation_id,
          legacy_created_at: core.created_at,
          claimed_at: now
        })
      )

    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, record} ->
        clear_exception(scope, core.id)
        {:ok, record}

      {:error, %Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :affiliation_id),
          do: {:error, :duplicate_affiliation},
          else: {:error, :invalid_facts}
    end
  end

  defp record_exception(scope, core, reason, now) do
    Repo.insert_all(
      EmploymentException,
      [
        %{
          tenant_id: Scope.tenant_id(scope),
          company_id: core.company_id,
          legacy_employee_id: core.id,
          reason: Atom.to_string(reason),
          detected_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:reason, :detected_at, :updated_at]},
      conflict_target: [:legacy_employee_id]
    )

    :ok
  end

  defp clear_exception(scope, employee_id) do
    Repo.delete_all(
      from(row in Tenancy.scope_query(EmploymentException, scope),
        where: row.legacy_employee_id == ^employee_id
      )
    )
  end

  defp clear_exceptions(scope, company_id) do
    Repo.delete_all(
      from(row in Tenancy.scope_query(EmploymentException, scope),
        where: row.company_id == ^company_id
      )
    )
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
