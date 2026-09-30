defmodule Bilimbi.People.Leave.CarryForward do
  @moduledoc false
  # Year-end carry-forward behind the `Bilimbi.People.Leave` facade.
  #
  # For each active type whose policy in force on the last day of the leave
  # year sets a carry-forward cap, every current employee's closing balance
  # up to the cap moves into the next year and any excess expires in the
  # closed year. A negative balance carries nothing and its deficit stays.
  #
  # Every processed employee and type gets one `carried_forward` entry, even
  # of zero, keyed by type, employee and year. That entry closes the year and
  # every earlier year for them: a replay skips it, and requests, approvals,
  # cancellations and entries into those years are refused, so no quantity is
  # spent twice. Years close in order per employee and type: an employee with
  # an earlier year still open is skipped instead of closed. Each run replaces
  # its year's stored skip report, which `skipped/3` reads.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.{CarryForwardSkip, LedgerEntry, LeaveType, Policy, Request, Requests}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @source "carry_forward"

  @doc """
  Whether `year` is closed to new requests and entries for the employee and
  type: it or any later year has been carried forward.
  """
  def closed?(scope, company_id, employee_id, type_id, year) do
    Repo.exists?(
      from(e in carried_entries(scope, company_id, employee_id, type_id),
        where: e.leave_year > ^year
      )
    )
  end

  # A year's closing entry lives in the following year.
  defp carried_entries(scope, company_id, employee_id, type_id) do
    from(e in Tenancy.scope_query(LedgerEntry, scope),
      where:
        e.company_id == ^company_id and e.employee_id == ^employee_id and
          e.leave_type_id == ^type_id and e.source == @source and
          e.entry_type == "carried_forward"
    )
  end

  @doc "How many employee balances of `from_year` have been carried forward."
  def closed_count(%Scope{} = scope, company_id, from_year) when is_integer(from_year) do
    with {:ok, _rules} <- Leave.rules(scope, company_id) do
      {:ok,
       Repo.one(
         from(e in Tenancy.scope_query(LedgerEntry, scope),
           where:
             e.company_id == ^company_id and e.source == @source and
               e.entry_type == "carried_forward" and e.leave_year == ^(from_year + 1),
           select: count(e.id)
         )
       )}
    end
  end

  def run(scope, company_id, from_year, actor_user_id \\ nil)

  def run(%Scope{} = scope, company_id, from_year, actor_user_id)
      when is_integer(from_year) and from_year in 1900..9997 do
    with {:ok, year} <- ended_year(scope, company_id, from_year),
         {:ok, read} <- Workforce.employees(scope, company_id),
         {:ok, employees} <- ReadResult.require_current(read) do
      Repo.transaction(fn ->
        types = carrying_types(scope, company_id, year.last_day)

        {counts, skips} =
          for {type, policy} <- types,
              employee <- employees,
              reduce:
                {%{
                   carried: 0,
                   existing: 0,
                   pending: 0,
                   previous_year_open: 0
                 }, []} do
            {counts, skips} ->
              employee_id = String.to_integer(employee.reference.stable_id)

              case Employee.lock_affiliation(scope, company_id, employee_id) do
                {:ok, _proof} -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              case status(scope, company_id, employee_id, type.id, from_year, year.rules) do
                :closed ->
                  {Map.update!(counts, :existing, &(&1 + 1)), skips}

                :open ->
                  close(
                    scope,
                    company_id,
                    employee_id,
                    type,
                    policy,
                    from_year,
                    actor_user_id,
                    year
                  )

                  {Map.update!(counts, :carried, &(&1 + 1)), skips}

                reason ->
                  skip = %{
                    employee_id: employee_id,
                    employee_label: "#{employee.display_name} (#{employee.employee_number})",
                    leave_type_id: type.id,
                    reason: Atom.to_string(reason)
                  }

                  {Map.update!(counts, reason, &(&1 + 1)), [skip | skips]}
              end
          end

        record_skips(scope, company_id, from_year, skips)
        counts
      end)
    end
  end

  def run(%Scope{}, _, _, _), do: {:error, :invalid_year}

  @doc """
  The employees and types the latest carry-forward run of `from_year` left
  open, with the reason: `:pending` requests in that year, or an earlier
  year still open (`:previous_year_open`).
  """
  def skipped(%Scope{} = scope, company_id, from_year) when is_integer(from_year) do
    with {:ok, _rules} <- Leave.rules(scope, company_id) do
      {:ok,
       Repo.all(
         from(s in Tenancy.scope_query(CarryForwardSkip, scope),
           join: t in LeaveType,
           on: t.id == s.leave_type_id,
           where: s.company_id == ^company_id and s.from_year == ^from_year,
           order_by: [asc: s.employee_label, asc: t.name],
           select: %{
             employee_id: s.employee_id,
             employee_name: s.employee_label,
             leave_type_id: s.leave_type_id,
             leave_type_name: t.name,
             reason: s.reason
           }
         )
       )
       |> Enum.map(&Map.update!(&1, :reason, fn reason -> String.to_existing_atom(reason) end))}
    end
  end

  def skipped(%Scope{}, _, _), do: {:error, :invalid_year}

  defp record_skips(scope, company_id, from_year, skips) do
    Repo.delete_all(
      from(s in Tenancy.scope_query(CarryForwardSkip, scope),
        where: s.company_id == ^company_id and s.from_year == ^from_year
      )
    )

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      CarryForwardSkip,
      Enum.map(
        skips,
        &Map.merge(&1, %{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          from_year: from_year,
          inserted_at: now
        })
      )
    )
  end

  defp ended_year(scope, company_id, from_year) do
    with {:ok, rules} <- Leave.rules(scope, company_id),
         {:ok, today} <- Leave.today(scope, company_id) do
      {first_next, _} = Leave.year_range(rules, from_year + 1)
      last_day = Date.add(first_next, -1)

      if Date.compare(last_day, today) == :lt,
        do: {:ok, %{rules: rules, last_day: last_day, first_next: first_next}},
        else: {:error, :year_not_ended}
    end
  end

  defp status(scope, company_id, employee_id, type_id, year, rules) do
    cond do
      closed?(scope, company_id, employee_id, type_id, year) ->
        :closed

      Requests.pending_exists?(scope, company_id, type_id, employee_id, year) ->
        :pending

      earlier_open?(scope, company_id, employee_id, type_id, year, rules) ->
        :previous_year_open

      true ->
        :open
    end
  end

  # An earlier year after the last carried one is open while it has pending
  # requests, or ledger entries under a capped policy. Uncapped years never
  # carry; closing a later year closes them.
  defp earlier_open?(scope, company_id, employee_id, type_id, year, rules) do
    after_year =
      Repo.one(
        from(e in carried_entries(scope, company_id, employee_id, type_id),
          select: max(e.leave_year) - 1
        )
      ) || 0

    pending? =
      Repo.exists?(
        from(r in Tenancy.scope_query(Request, scope),
          where:
            r.company_id == ^company_id and r.employee_id == ^employee_id and
              r.leave_type_id == ^type_id and r.status == "pending" and
              r.leave_year > ^after_year and r.leave_year < ^year
        )
      )

    pending? or
      Repo.all(
        from(e in Tenancy.scope_query(LedgerEntry, scope),
          where:
            e.company_id == ^company_id and e.employee_id == ^employee_id and
              e.leave_type_id == ^type_id and e.leave_year > ^after_year and
              e.leave_year < ^year,
          distinct: true,
          select: e.leave_year
        )
      )
      |> Enum.any?(&capped?(scope, company_id, type_id, rules, &1))
  end

  defp capped?(scope, company_id, type_id, rules, year) do
    {first_next, _} = Leave.year_range(rules, year + 1)
    last_day = Date.add(first_next, -1)

    Repo.exists?(
      from(p in Tenancy.scope_query(Policy, scope),
        where:
          p.company_id == ^company_id and p.leave_type_id == ^type_id and
            p.effective_from <= ^last_day and
            (is_nil(p.effective_to) or p.effective_to >= ^last_day) and
            not is_nil(p.carry_forward_cap)
      )
    )
  end

  # FOR SHARE, as request submission takes it, so neither blocks the other
  # while holding an employee lock the other waits for.
  defp carrying_types(scope, company_id, last_day) do
    Repo.all(
      from(t in Tenancy.scope_query(LeaveType, scope),
        join: p in Policy,
        on: p.leave_type_id == t.id,
        where: t.company_id == ^company_id and t.status == "active",
        where: p.effective_from <= ^last_day,
        where: is_nil(p.effective_to) or p.effective_to >= ^last_day,
        where: not is_nil(p.carry_forward_cap),
        order_by: [asc: t.id],
        lock: "FOR SHARE",
        select: {t, p}
      )
    )
  end

  defp close(scope, company_id, employee_id, type, policy, year, actor_user_id, dates) do
    remaining =
      Repo.one(
        from(e in Tenancy.scope_query(LedgerEntry, scope),
          where:
            e.company_id == ^company_id and e.employee_id == ^employee_id and
              e.leave_type_id == ^type.id and e.leave_year == ^year,
          select: coalesce(sum(e.quantity), 0)
        )
      )
      |> Decimal.new()

    zero = Decimal.new("0.00")
    carried = remaining |> Decimal.min(policy.carry_forward_cap) |> Decimal.max(zero)
    expired = remaining |> Decimal.sub(carried) |> Decimal.max(zero)

    base = %{
      unit: type.unit,
      policy_id: policy.id,
      policy_version: policy.version,
      source: @source,
      actor_user_id: actor_user_id
    }

    insert!(
      scope,
      company_id,
      employee_id,
      type,
      Map.merge(base, %{
        leave_year: year + 1,
        entry_type: "carried_forward",
        quantity: Decimal.round(carried, 2),
        occurred_on: dates.first_next,
        entry_key: key("carry", type.id, employee_id, year)
      })
    )

    if Decimal.gt?(expired, 0) do
      insert!(
        scope,
        company_id,
        employee_id,
        type,
        Map.merge(base, %{
          leave_year: year,
          entry_type: "expired",
          quantity: expired |> Decimal.negate() |> Decimal.round(2),
          occurred_on: dates.last_day,
          entry_key: key("expire", type.id, employee_id, year)
        })
      )
    end
  end

  defp insert!(scope, company_id, employee_id, type, attrs) do
    %LedgerEntry{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      employee_id: employee_id,
      leave_type_id: type.id
    }
    |> LedgerEntry.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, entry} -> entry
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp key(kind, type_id, employee_id, year), do: "#{kind}:#{type_id}:#{employee_id}:#{year}"
end
