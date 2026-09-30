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
  # Years close in order: a run that would carry into an already closed next
  # year is refused as a whole.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.{LedgerEntry, LeaveType, Policy, Requests}
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
    with {:ok, rules} <- Leave.rules(scope, company_id),
         {:ok, today} <- Leave.today(scope, company_id),
         {first_next, _} = Leave.year_range(rules, from_year + 1),
         :lt <- Date.compare(Date.add(first_next, -1), today),
         {:ok, read} <- Workforce.employees(scope, company_id),
         {:ok, employees} <- ReadResult.require_current(read) do
      last_day = Date.add(first_next, -1)

      Repo.transaction(fn ->
        for {type, policy} <- carrying_types(scope, company_id, last_day),
            employee <- employees,
            reduce: %{carried: 0, existing: 0, pending: 0} do
          counts ->
            employee_id = String.to_integer(employee.reference.stable_id)

            case Employee.lock_affiliation(scope, company_id, employee_id) do
              {:ok, _proof} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            cond do
              closed?(scope, company_id, employee_id, type.id, from_year) ->
                Map.update!(counts, :existing, &(&1 + 1))

              Requests.pending_exists?(scope, company_id, type.id, employee_id, from_year) ->
                Map.update!(counts, :pending, &(&1 + 1))

              closed?(scope, company_id, employee_id, type.id, from_year + 1) ->
                Repo.rollback(:next_year_closed)

              true ->
                close(scope, company_id, employee_id, type, policy, from_year, actor_user_id, %{
                  first_next: first_next,
                  last_day: last_day
                })

                Map.update!(counts, :carried, &(&1 + 1))
            end
        end
      end)
    else
      :gt -> {:error, :year_not_ended}
      :eq -> {:error, :year_not_ended}
      error -> error
    end
  end

  def run(%Scope{}, _, _, _), do: {:error, :invalid_year}

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
