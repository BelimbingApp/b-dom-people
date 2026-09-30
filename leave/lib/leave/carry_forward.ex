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
  # of zero, keyed by type, employee and year. That entry closes the year for
  # them: a replay skips it, and requests, approvals, cancellations and
  # entries into that year are refused, so no quantity is spent twice.
  # Years close in order per employee and type: an employee whose previous
  # year is still open, or whose next year is already closed over a balance,
  # is skipped instead of closed. Each run replaces its year's stored skip
  # report, which `skipped/3` reads.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.{CarryForwardSkip, LedgerEntry, LeaveType, Policy, Requests}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @source "carry_forward"

  def closed?(scope, company_id, employee_id, type_id, year) do
    Repo.exists?(
      from(e in Tenancy.scope_query(LedgerEntry, scope),
        where:
          e.company_id == ^company_id and e.source == @source and
            e.entry_key == ^key("carry", type_id, employee_id, year)
      )
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
        {types, previous} = carrying(scope, company_id, year)

        {counts, skips} =
          for {type, policy} <- types,
              employee <- employees,
              reduce:
                {%{
                   carried: 0,
                   existing: 0,
                   pending: 0,
                   previous_year_open: 0,
                   next_year_closed: 0
                 }, []} do
            {counts, skips} ->
              employee_id = String.to_integer(employee.reference.stable_id)

              case Employee.lock_affiliation(scope, company_id, employee_id) do
                {:ok, _proof} -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              case status(scope, company_id, employee_id, type.id, from_year, previous) do
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
  open, with the reason: `:pending` requests in that year, the
  `:previous_year_open`, or the `:next_year_closed` over a balance.
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
      {first, _} = Leave.year_range(rules, from_year)
      {first_next, _} = Leave.year_range(rules, from_year + 1)
      last_day = Date.add(first_next, -1)

      if Date.compare(last_day, today) == :lt,
        do:
          {:ok,
           %{previous_last_day: Date.add(first, -1), last_day: last_day, first_next: first_next}},
        else: {:error, :year_not_ended}
    end
  end

  defp carrying(scope, company_id, year) do
    previous =
      scope
      |> carrying_types(company_id, year.previous_last_day)
      |> MapSet.new(fn {type, _policy} -> type.id end)

    {carrying_types(scope, company_id, year.last_day), previous}
  end

  # Years close in order, per employee and type: a year is carried only once
  # the previous one is no longer open and while the next one is still open.
  defp status(scope, company_id, employee_id, type_id, year, previous) do
    cond do
      closed?(scope, company_id, employee_id, type_id, year) ->
        :closed

      Requests.pending_exists?(scope, company_id, type_id, employee_id, year) ->
        :pending

      type_id in previous and open?(scope, company_id, employee_id, type_id, year - 1) ->
        :previous_year_open

      closed?(scope, company_id, employee_id, type_id, year + 1) and
          active?(scope, company_id, employee_id, type_id, year) ->
        :next_year_closed

      true ->
        :open
    end
  end

  defp open?(scope, company_id, employee_id, type_id, year) do
    not closed?(scope, company_id, employee_id, type_id, year) and
      (active?(scope, company_id, employee_id, type_id, year) or
         Requests.pending_exists?(scope, company_id, type_id, employee_id, year))
  end

  defp active?(scope, company_id, employee_id, type_id, year) do
    Repo.exists?(
      from(e in Tenancy.scope_query(LedgerEntry, scope),
        where:
          e.company_id == ^company_id and e.employee_id == ^employee_id and
            e.leave_type_id == ^type_id and e.leave_year == ^year
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
