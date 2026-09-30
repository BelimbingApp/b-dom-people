defmodule Bilimbi.People.Leave do
  @moduledoc """
  Company-scoped leave types, effective-dated entitlement policies, an
  append-only balance ledger, leave requests with approval, and year-end
  carry-forward.

  Every operation takes a validated tenant scope and an explicit platform
  company ID. Company and employee identity come from `people/workforce` and
  must be current. Callers never query the schemas directly.
  """
  import Ecto.Query
  import Bilimbi.People.Leave.Input, only: [field: 2, parse_date: 1, parse_quantity: 1]

  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Queue
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.User

  alias Bilimbi.People.Leave.{
    CarryForward,
    CarryForwardWorker,
    LedgerEntry,
    LeaveType,
    Policy,
    Requests
  }

  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @year_start_key "people.leave.year_start_month"
  @grant_source "policy"
  @reserved_sources ~w(policy request carry_forward)

  ## Company leave year

  def rules(%Scope{} = scope, company_id) do
    with {:ok, company} <- current_company(scope, company_id) do
      {:ok, %{year_start_month: Settings.get(@year_start_key, settings_scope(scope, company))}}
    end
  end

  @doc "Refused once the company has ledger entries, which carry their leave year."
  def put_rules(%Scope{} = scope, company_id, month) when month in 1..12 do
    with {:ok, company} <- current_company(scope, company_id) do
      Repo.transaction(fn ->
        lock_types(scope, company_id)
        %{year_start_month: current} = unwrap(rules(scope, company_id))

        cond do
          current == month ->
            %{year_start_month: month}

          ledger_in_use?(scope, company_id) ->
            Repo.rollback(:year_in_use)

          true ->
            unwrap(Settings.put(@year_start_key, month, settings_scope(scope, company)))
            unwrap(rules(scope, company_id))
        end
      end)
    end
  end

  def put_rules(%Scope{}, _, _), do: {:error, :invalid_rules}

  @doc "The leave year containing `date`, labelled by the calendar year it starts in."
  def leave_year(%{year_start_month: month}, %Date{} = date),
    do: if(date.month >= month, do: date.year, else: date.year - 1)

  def year_range(%{year_start_month: month}, year) when is_integer(year) do
    first = Date.new!(year, month, 1)
    {first, Date.add(Date.shift(first, year: 1), -1)}
  end

  ## Types

  def list_types(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(t in Tenancy.scope_query(LeaveType, scope),
           where: t.company_id == ^company_id,
           order_by: [asc: t.status, asc: t.name, asc: t.id]
         )
       )
       |> Enum.map(&type_view/1)}
    end
  end

  def create_type(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- current_company(scope, company_id) do
      %LeaveType{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> LeaveType.changeset(
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(~w(code name unit paid balance_required))
        |> Map.put("status", "active")
      )
      |> Repo.insert()
      |> case do
        {:ok, type} -> {:ok, type_view(type)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def set_type_status(%Scope{} = scope, company_id, type_id, status)
      when status in ["active", "archived"] do
    with {:ok, _company} <- current_company(scope, company_id),
         %LeaveType{} = type <- get_type(scope, company_id, type_id) do
      type |> LeaveType.changeset(%{status: status}) |> Repo.update() |> view_result(&type_view/1)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def set_type_status(%Scope{}, _, _, _), do: {:error, :invalid_status}

  ## Policies

  def list_policies(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(p in Tenancy.scope_query(Policy, scope),
           where: p.company_id == ^company_id,
           order_by: [asc: p.leave_type_id, desc: p.version]
         )
       )
       |> Enum.map(&policy_view/1)}
    end
  end

  @doc """
  Adds the next policy version for an active type. It must start after the
  latest version, which it closes the day before, and after every entitlement
  already granted for that type, so no grant is left under a policy that no
  longer covers it. An optional `carry_forward_cap` is the most of a closing
  balance that carry-forward moves into the next leave year; without one the
  type does not carry forward.
  """
  def add_policy(%Scope{} = scope, company_id, type_id, attrs, actor_user_id \\ nil)
      when is_map(attrs) do
    with {:ok, _company} <- current_company(scope, company_id),
         {:ok, effective_from} <- parse_date(field(attrs, :effective_from)),
         {:ok, entitlement} <- parse_quantity(field(attrs, :entitlement)),
         true <- Decimal.compare(entitlement, 0) != :lt || {:error, :invalid_policy},
         {:ok, cap} <- parse_cap(field(attrs, :carry_forward_cap)) do
      Repo.transaction(fn ->
        type = lock_active_type(scope, company_id, type_id) || Repo.rollback(:not_found)
        latest = latest_policy(scope, type.id)

        cond do
          latest && Date.compare(effective_from, latest.effective_from) != :gt ->
            Repo.rollback(:not_after_latest)

          granted_on_or_after?(scope, company_id, type.id, effective_from) ->
            Repo.rollback(:granted_after_effective_date)

          true ->
            if latest,
              do:
                latest
                |> Ecto.Changeset.change(effective_to: Date.add(effective_from, -1))
                |> Repo.update!()

            %Policy{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              leave_type_id: type.id,
              version: if(latest, do: latest.version + 1, else: 1)
            }
            |> Policy.changeset(%{
              effective_from: effective_from,
              entitlement: entitlement,
              carry_forward_cap: cap,
              actor_user_id: actor_user_id
            })
            |> Repo.insert()
            |> case do
              {:ok, policy} -> policy_view(policy)
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
    end
  end

  def policy_on(%Scope{} = scope, company_id, type_id, %Date{} = date) do
    with {:ok, _company} <- current_company(scope, company_id) do
      case effective_policy(scope, company_id, type_id, date) do
        nil -> {:error, :not_found}
        policy -> {:ok, policy_view(policy)}
      end
    end
  end

  ## Ledger

  @doc """
  Grants each current workforce employee the entitlement of every active type
  whose policy is effective on the first day of `leave_year`. A grant happens
  once per employee, type and year; a repeated run skips existing grants, and
  an employee and type whose year is already carried forward is counted as
  `closed` and not granted.
  """
  def grant_entitlements(scope, company_id, leave_year, actor_user_id \\ nil)

  def grant_entitlements(%Scope{} = scope, company_id, leave_year, actor_user_id)
      when is_integer(leave_year) and leave_year in 1900..9998 do
    with {:ok, read} <- Workforce.employees(scope, company_id),
         {:ok, employees} <- ReadResult.require_current(read) do
      Repo.transaction(fn ->
        types = scope |> lock_types(company_id) |> Enum.filter(&(&1.status == "active"))
        {first_day, _} = year_range(unwrap(rules(scope, company_id)), leave_year)

        for type <- types,
            policy = effective_policy(scope, company_id, type.id, first_day),
            policy != nil,
            employee <- employees,
            reduce: %{granted: 0, existing: 0, closed: 0} do
          counts ->
            employee_id = String.to_integer(employee.reference.stable_id)
            key = "entitlement:#{type.id}:#{employee_id}:#{leave_year}"

            changeset =
              %LedgerEntry{
                tenant_id: Scope.tenant_id(scope),
                company_id: company_id,
                employee_id: employee_id,
                leave_type_id: type.id
              }
              |> LedgerEntry.changeset(%{
                leave_year: leave_year,
                entry_type: "entitlement",
                quantity: policy.entitlement,
                unit: type.unit,
                policy_id: policy.id,
                policy_version: policy.version,
                occurred_on: first_day,
                source: @grant_source,
                entry_key: key,
                actor_user_id: actor_user_id
              })

            # Checking first keeps a repeated grant from issuing a no-op insert;
            # the savepoint absorbs a concurrent run that wins the unique key.
            with nil <- find_entry(scope, company_id, @grant_source, key),
                 false <-
                   CarryForward.closed?(scope, company_id, employee_id, type.id, leave_year),
                 {:ok, _entry} <- Repo.insert(changeset, mode: :savepoint) do
              Map.update!(counts, :granted, &(&1 + 1))
            else
              %LedgerEntry{} -> Map.update!(counts, :existing, &(&1 + 1))
              true -> Map.update!(counts, :closed, &(&1 + 1))
              {:error, changeset} -> replayed_grant(scope, company_id, key, changeset, counts)
            end
        end
      end)
    end
  end

  def grant_entitlements(%Scope{}, _, _, _), do: {:error, :invalid_year}

  @doc """
  Records an opening balance or adjustment. Idempotent by company, source and
  key; a replay with different facts is refused, and so is a new entry in a
  leave year already carried forward for that employee and type.
  """
  def record_entry(%Scope{} = scope, company_id, employee_id, attrs) when is_map(attrs) do
    with {:ok, _employee} <- current_employee(scope, company_id, employee_id),
         {:ok, entry} <- normalize_entry(attrs) do
      Repo.transaction(fn ->
        type =
          lock_active_type(scope, company_id, entry.leave_type_id) || Repo.rollback(:not_found)

        rules = unwrap(rules(scope, company_id))

        attrs =
          entry
          |> Map.delete(:leave_type_id)
          |> Map.merge(%{leave_year: leave_year(rules, entry.occurred_on), unit: type.unit})

        case find_entry(scope, company_id, entry.source, entry.entry_key) do
          nil ->
            if CarryForward.closed?(scope, company_id, employee_id, type.id, attrs.leave_year),
              do: Repo.rollback(:year_closed)

            %LedgerEntry{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              employee_id: employee_id,
              leave_type_id: type.id
            }
            |> LedgerEntry.changeset(attrs)
            |> Repo.insert(mode: :savepoint)
            |> case do
              {:ok, saved} ->
                entry_view(saved)

              {:error, changeset} ->
                replay_after_race(scope, company_id, employee_id, type, attrs, changeset)
            end

          existing ->
            replay_entry(existing, employee_id, type.id, attrs)
        end
      end)
    end
  end

  @doc """
  Per-type totals for one employee and leave year, derived from the ledger.
  `pending` is the quantity held by pending requests; `available` is the
  balance less that reservation.
  """
  def balances(%Scope{} = scope, company_id, employee_id, leave_year)
      when is_integer(leave_year) do
    with {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      totals =
        Repo.all(
          from(e in Tenancy.scope_query(LedgerEntry, scope),
            where:
              e.company_id == ^company_id and e.employee_id == ^employee_id and
                e.leave_year == ^leave_year,
            group_by: [e.leave_type_id, e.entry_type],
            select: {e.leave_type_id, e.entry_type, sum(e.quantity)}
          )
        )
        |> Enum.group_by(&elem(&1, 0), fn {_, type, sum} -> {type, sum} end)

      pending = Requests.pending_totals(scope, company_id, employee_id, leave_year)

      {:ok,
       company_types(scope, company_id)
       |> Enum.filter(&(&1.status == "active" or Map.has_key?(totals, &1.id)))
       |> Enum.map(
         &balance_view(&1, Map.new(Map.get(totals, &1.id, [])), Map.get(pending, &1.id))
       )}
    end
  end

  def entries(%Scope{} = scope, company_id, employee_id, leave_year)
      when is_integer(leave_year) do
    with {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      {:ok,
       Repo.all(
         from(e in Tenancy.scope_query(LedgerEntry, scope),
           where:
             e.company_id == ^company_id and e.employee_id == ^employee_id and
               e.leave_year == ^leave_year,
           order_by: [desc: e.occurred_on, desc: e.id]
         )
       )
       |> Enum.map(&entry_view/1)}
    end
  end

  ## Requests and approval

  @doc """
  The company's request rules: `working_weekdays` (ISO weekday numbers
  counted as leave days) and `backdate_days` (how many days before today a
  request may start). Calendar exceptions from `people/reference_data` are
  never counted.
  """
  defdelegate request_rules(scope, company_id), to: Requests

  @doc "Saves `working_weekdays` (non-empty, 1..7) and `backdate_days` (0..366)."
  defdelegate put_request_rules(scope, company_id, attrs), to: Requests

  @doc """
  Submits a request for the actor's linked working employee. `day_part` is
  `full` over the range, `am` or `pm` for half of one day, or `hours` with
  `hours` for an hour-unit type on one day. Idempotent by `request_key`.

  Refusals include `:invalid_request`, `:not_found`, `:spans_leave_years`,
  `:too_far_back`, `:year_closed`, `:no_working_days`, `:overlapping_request`,
  `:insufficient_balance`, `:request_key_conflict` and `:unavailable`.
  """
  defdelegate submit_request(scope, company_id, actor, attrs), to: Requests, as: :submit

  @doc "The actor's own latest requests, newest start first."
  defdelegate self_requests(scope, company_id, actor), to: Requests

  @doc """
  Cancels the actor's own request: pending at any time, approved only before
  its start date, which writes a `cancelled` entry returning the quantity.
  """
  defdelegate cancel_request(scope, company_id, actor, request_id), to: Requests, as: :cancel

  @doc "A company's pending requests, earliest start first, with employee names."
  defdelegate pending_requests(scope, company_id), to: Requests, as: :pending

  @doc """
  Approves (`:approve`) or rejects (`:reject`, note required) a pending
  request. Refuses the requester and the employee (`:self_approval`), a
  request no longer pending (`:not_pending`), a closed year and a balance
  that no longer covers it. Approval writes the `taken` entry.
  """
  defdelegate decide_request(scope, company_id, actor, request_id, decision, note),
    to: Requests,
    as: :decide

  ## Carry-forward

  @doc """
  Carries each current employee's closing balance of `from_year`, up to the
  cap of the policy in force on its last day, into the next leave year and
  expires the excess. Refused until that year has ended. Years close in order
  per employee and type, so an employee with pending requests in that year or
  with an earlier year still open is skipped; a repeated run changes nothing.
  Returns counts of `carried` and `existing` balances and of each skip reason:
  `pending` and `previous_year_open`.
  """
  defdelegate carry_forward(scope, company_id, from_year, actor_user_id \\ nil),
    to: CarryForward,
    as: :run

  @doc "How many balances of `from_year` have been carried forward."
  defdelegate carried_forward_count(scope, company_id, from_year),
    to: CarryForward,
    as: :closed_count

  @doc "Employees and types the latest carry-forward run of `from_year` skipped, with the reason."
  defdelegate carry_forward_skipped(scope, company_id, from_year),
    to: CarryForward,
    as: :skipped

  @doc "Queues `carry_forward/4` to run as the signed-in operator."
  def enqueue_carry_forward(%Scope{} = scope, company_id, from_year)
      when is_integer(company_id) and is_integer(from_year) do
    case Queue.enqueue_for(scope, CarryForwardWorker, %{
           "company_id" => company_id,
           "from_year" => from_year
         }) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_carry_forward(%Scope{}, _, _), do: {:error, :invalid_carry_forward}

  @doc """
  Balances and entries of the logged-in actor's linked employee for the leave
  year containing `on`, by default today in the company time zone.
  """
  def self_summary(%Scope{} = scope, company_id, actor, on \\ nil) do
    with {:ok, employee_id} <- self_employee(scope, company_id, actor),
         {:ok, rules} <- rules(scope, company_id),
         {:ok, on} <- summary_date(scope, company_id, on),
         year = leave_year(rules, on),
         {:ok, balances} <- balances(scope, company_id, employee_id, year),
         {:ok, entries} <- entries(scope, company_id, employee_id, year) do
      {first, last} = year_range(rules, year)

      {:ok,
       %{leave_year: year, starts_on: first, ends_on: last, balances: balances, entries: entries}}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Today's date in the company time zone."
  def today(%Scope{} = scope, company_id) do
    with {:ok, company} <- current_company(scope, company_id),
         timezone = BaseDateTime.company_timezone(settings_scope(scope, company)),
         {:ok, local} <- BaseDateTime.shift(DateTime.utc_now(), timezone),
         do: {:ok, DateTime.to_date(local)}
  end

  ## Private

  defp settings_scope(scope, company),
    do: SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

  defp summary_date(_scope, _company_id, %Date{} = on), do: {:ok, on}
  defp summary_date(scope, company_id, nil), do: today(scope, company_id)

  defp current_company(scope, company_id) do
    with {:ok, read} <- Workforce.company(scope, company_id),
         do: ReadResult.require_current(read)
  end

  defp current_employee(scope, company_id, employee_id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, employee_id),
         do: ReadResult.require_current(read)
  end

  defp self_employee(scope, company_id, actor) do
    with true <- actor.type == :user and actor.company_id == company_id,
         {:ok, user} <- User.get_user(scope, company_id, actor.id),
         employee_id when is_integer(employee_id) <- user.employee_id,
         {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      {:ok, employee_id}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp ledger_in_use?(scope, company_id),
    do:
      Repo.exists?(
        from(e in Tenancy.scope_query(LedgerEntry, scope), where: e.company_id == ^company_id)
      )

  defp company_types(scope, company_id),
    do:
      Repo.all(
        from(t in Tenancy.scope_query(LeaveType, scope),
          where: t.company_id == ^company_id,
          order_by: [asc: t.name, asc: t.id]
        )
      )

  defp get_type(scope, company_id, type_id) when is_integer(type_id),
    do:
      Repo.one(
        from(t in Tenancy.scope_query(LeaveType, scope),
          where: t.company_id == ^company_id and t.id == ^type_id
        )
      )

  defp get_type(_, _, _), do: nil

  defp lock_active_type(scope, company_id, type_id) when is_integer(type_id),
    do:
      Repo.one(
        from(t in Tenancy.scope_query(LeaveType, scope),
          where: t.company_id == ^company_id and t.id == ^type_id and t.status == "active",
          lock: "FOR UPDATE"
        )
      )

  defp lock_active_type(_, _, _), do: nil

  defp lock_types(scope, company_id),
    do:
      Repo.all(
        from(t in Tenancy.scope_query(LeaveType, scope),
          where: t.company_id == ^company_id,
          order_by: [asc: t.id],
          lock: "FOR UPDATE"
        )
      )

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp latest_policy(scope, type_id),
    do:
      Repo.one(
        from(p in Tenancy.scope_query(Policy, scope),
          where: p.leave_type_id == ^type_id,
          order_by: [desc: p.version],
          limit: 1
        )
      )

  defp effective_policy(scope, company_id, type_id, date),
    do:
      Repo.one(
        from(p in Tenancy.scope_query(Policy, scope),
          where:
            p.company_id == ^company_id and p.leave_type_id == ^type_id and
              p.effective_from <= ^date and (is_nil(p.effective_to) or p.effective_to >= ^date)
        )
      )

  defp granted_on_or_after?(scope, company_id, type_id, date),
    do:
      Repo.exists?(
        from(e in Tenancy.scope_query(LedgerEntry, scope),
          where:
            e.company_id == ^company_id and e.leave_type_id == ^type_id and
              e.entry_type == "entitlement" and e.occurred_on >= ^date
        )
      )

  defp find_entry(scope, company_id, source, key),
    do:
      Repo.one(
        from(e in Tenancy.scope_query(LedgerEntry, scope),
          where: e.company_id == ^company_id and e.source == ^source and e.entry_key == ^key
        )
      )

  defp replayed_grant(scope, company_id, key, changeset, counts) do
    if find_entry(scope, company_id, @grant_source, key),
      do: Map.update!(counts, :existing, &(&1 + 1)),
      else: Repo.rollback(changeset)
  end

  defp replay_after_race(scope, company_id, employee_id, type, attrs, changeset) do
    if Enum.any?(changeset.errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end) do
      case find_entry(scope, company_id, attrs.source, attrs.entry_key) do
        nil -> Repo.rollback(:entry_key_conflict)
        existing -> replay_entry(existing, employee_id, type.id, attrs)
      end
    else
      Repo.rollback(changeset)
    end
  end

  defp replay_entry(existing, employee_id, type_id, attrs) do
    if existing.employee_id == employee_id and existing.leave_type_id == type_id and
         existing.entry_type == attrs.entry_type and
         Decimal.equal?(existing.quantity, attrs.quantity) and
         existing.occurred_on == attrs.occurred_on and existing.note == attrs.note,
       do: entry_view(existing),
       else: Repo.rollback(:entry_key_conflict)
  end

  defp normalize_entry(attrs) do
    entry_type = field(attrs, :entry_type)
    source = field(attrs, :source)
    key = field(attrs, :entry_key)
    note = field(attrs, :note)

    with true <- entry_type in ~w(opening adjustment),
         true <- is_integer(field(attrs, :leave_type_id)),
         true <-
           is_binary(source) and byte_size(source) in 1..32 and source not in @reserved_sources,
         true <- is_binary(key) and byte_size(key) in 1..160,
         true <- is_nil(note) or (is_binary(note) and String.length(note) <= 500),
         {:ok, occurred_on} <- parse_date(field(attrs, :occurred_on)),
         {:ok, quantity} <- parse_quantity(field(attrs, :quantity)),
         true <- not Decimal.eq?(quantity, 0) do
      {:ok,
       %{
         leave_type_id: field(attrs, :leave_type_id),
         entry_type: entry_type,
         quantity: quantity,
         occurred_on: occurred_on,
         source: source,
         entry_key: key,
         actor_user_id: field(attrs, :actor_user_id),
         note: note
       }}
    else
      _ -> {:error, :invalid_entry}
    end
  end

  defp parse_cap(nil), do: {:ok, nil}

  defp parse_cap(value) do
    case if(is_binary(value), do: String.trim(value), else: value) do
      "" -> {:ok, nil}
      value -> non_negative_cap(parse_quantity(value))
    end
  end

  defp non_negative_cap(result) do
    case result do
      {:ok, cap} -> if Decimal.negative?(cap), do: {:error, :invalid_policy}, else: {:ok, cap}
      error -> error
    end
  end

  defp view_result({:ok, value}, view), do: {:ok, view.(value)}
  defp view_result(error, _view), do: error

  defp type_view(type),
    do: Map.take(type, [:id, :code, :name, :unit, :paid, :balance_required, :status])

  defp policy_view(policy),
    do:
      Map.take(policy, [
        :id,
        :leave_type_id,
        :version,
        :effective_from,
        :effective_to,
        :entitlement,
        :carry_forward_cap
      ])

  defp entry_view(entry),
    do:
      Map.take(entry, [
        :id,
        :employee_id,
        :leave_type_id,
        :leave_year,
        :entry_type,
        :quantity,
        :unit,
        :policy_version,
        :occurred_on,
        :source,
        :note
      ])

  defp balance_view(type, sums, pending) do
    zero = Decimal.new("0.00")
    sum = fn types -> Enum.reduce(types, zero, &Decimal.add(Map.get(sums, &1, zero), &2)) end
    balance = Enum.reduce(Map.values(sums), zero, &Decimal.add/2)
    pending = pending || zero

    %{
      leave_type: type_view(type),
      entitlement: sum.(["entitlement"]),
      opening: sum.(["opening"]),
      adjustment: sum.(["adjustment"]),
      carried_forward: sum.(["carried_forward"]),
      # Taken leave net of cancelled approvals, as a positive quantity.
      taken: Decimal.sub(zero, sum.(["taken", "cancelled"])),
      expired: Decimal.sub(zero, sum.(["expired"])),
      balance: balance,
      pending: pending,
      available: Decimal.sub(balance, pending)
    }
  end
end
