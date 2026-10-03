defmodule Bilimbi.People.Leave.Requests do
  @moduledoc false
  # Leave requests behind the `Bilimbi.People.Leave` facade. An employee
  # requests leave for their own linked employee; a pending request reserves
  # its quantity and holds its half-day slots. An approver who is neither the
  # requester nor the employee decides. Approval writes a `taken` ledger entry;
  # cancelling an approved request before it starts writes a `cancelled` one.
  # Every write for one employee runs under Core Employee's affiliation lock,
  # so balance and overlap checks cannot race each other. Self-service calls
  # resolve the signed-in actor's linked employee on every call and prove it
  # again under that lock; approval calls authorize the approve capability
  # when they run.
  import Ecto.Query

  import Bilimbi.People.Leave.Input,
    only: [field: 2, parse_date: 1, parse_quantity: 1, optional_text: 2]

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.{CarryForward, LedgerEntry, LeaveType, Request, RequestDay}
  alias Bilimbi.People.Leave.RequestEvent
  alias Bilimbi.People.ReferenceData
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce.ReadResult

  @manage "people.leave.policies.manage"
  @approve "people.leave.requests.approve"
  @self "people.leave.self.view"
  @weekdays_key "people.leave.working_weekdays"
  @backdate_key "people.leave.request_backdate_days"
  @request_source "request"
  @max_span_days 366
  @max_hours Decimal.new(24)
  @self_limit 50
  @queue_limit 200

  @request_fields [
    :id,
    :employee_id,
    :leave_type_id,
    :leave_year,
    :starts_on,
    :ends_on,
    :day_part,
    :quantity,
    :unit,
    :status,
    :reason,
    :requested_by_user_id,
    :decided_by_user_id,
    :decided_at,
    :decision_note,
    :cancelled_by_user_id,
    :cancelled_at,
    :inserted_at
  ]

  ## Company request rules

  def request_rules(%Scope{} = scope, company_id) do
    with {:ok, company} <- current_company(scope, company_id) do
      settings = settings_scope(scope, company)

      {:ok,
       %{
         working_weekdays: Settings.get(@weekdays_key, settings),
         backdate_days: Settings.get(@backdate_key, settings)
       }}
    end
  end

  def put_request_rules(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    weekdays = field(attrs, :working_weekdays)
    backdate = field(attrs, :backdate_days)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage),
         {:ok, company} <- current_company(scope, company_id),
         true <- valid_weekdays?(weekdays) || {:error, :invalid_rules},
         true <- (is_integer(backdate) and backdate in 0..366) || {:error, :invalid_rules} do
      settings = settings_scope(scope, company)

      Repo.transaction(fn ->
        unwrap(Settings.put(@weekdays_key, weekdays |> Enum.uniq() |> Enum.sort(), settings))
        unwrap(Settings.put(@backdate_key, backdate, settings))
        unwrap(request_rules(scope, company_id))
      end)
    end
  end

  def put_request_rules(%Scope{}, _, _), do: {:error, :invalid_rules}

  defp valid_weekdays?(days),
    do: is_list(days) and days != [] and Enum.all?(days, &(&1 in 1..7))

  ## Self service

  @doc """
  Submits a request for the actor's linked working employee.

  `day_part` is `full` for whole days over the range, `am` or `pm` for half
  of a single day, and `hours` with `hours` for an hour-unit type on a single
  day. Only the company's working days that are not calendar exceptions are
  counted. A replay with the same `request_key` returns the request; a
  different request under that key is refused.
  """
  def submit(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, input} <- normalize_request(attrs) do
      Authorization.with_self_employee_lock(scope, company_id, @self, fn self ->
        %{actor: actor, employee_id: employee_id} = self

        case find_by_key(scope, company_id, employee_id, input.request_key) do
          nil -> insert_request(scope, company_id, employee_id, actor.id, input)
          existing -> replay(existing, input)
        end
      end)
    end
  end

  def submit(%Scope{}, _, _), do: {:error, :invalid_request}

  def self_requests(%Scope{} = scope, company_id) do
    with {:ok, %{employee_id: employee_id}} <-
           Authorization.authorize_self(scope, company_id, @self) do
      {:ok,
       Repo.all(
         from(r in Tenancy.scope_query(Request, scope),
           where: r.company_id == ^company_id and r.employee_id == ^employee_id,
           order_by: [desc: r.starts_on, desc: r.id],
           limit: @self_limit
         )
       )
       |> Enum.map(&request_view/1)}
    end
  end

  @doc """
  Cancels the actor's own request: a pending one at any time, an approved one
  only before it starts, which returns its quantity to the ledger.
  """
  def cancel(%Scope{} = scope, company_id, request_id) do
    Authorization.with_self_employee_lock(scope, company_id, @self, fn self ->
      %{actor: actor, employee_id: employee_id} = self

      with %Request{employee_id: ^employee_id} = request <-
             lock_request(scope, company_id, request_id) || {:error, :not_found},
           {:ok, today} <- Leave.today(scope, company_id) do
        cancel_request(scope, request, actor.id, today)
      else
        %Request{} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp cancel_request(scope, %Request{status: "pending"} = request, actor_id, _today) do
    transition(scope, request, "cancelled", actor_id, nil)
  end

  defp cancel_request(scope, %Request{status: "approved"} = request, actor_id, today) do
    cond do
      Date.compare(request.starts_on, today) != :gt ->
        {:error, :not_cancellable}

      CarryForward.closed?(
        scope,
        request.company_id,
        request.employee_id,
        request.leave_type_id,
        request.leave_year
      ) ->
        {:error, :year_closed}

      true ->
        with {:ok, _entry} <-
               write_entry(scope, request, "cancelled", request.quantity, actor_id) do
          transition(scope, request, "cancelled", actor_id, nil)
        end
    end
  end

  defp cancel_request(_scope, _request, _actor_id, _today), do: {:error, :not_cancellable}

  ## Approval

  @doc "Pending requests of a company, earliest start first, with employee names, for an approver."
  def pending(%Scope{} = scope, company_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @approve),
         {:ok, _company} <- current_company(scope, company_id) do
      requests =
        Repo.all(
          from(r in Tenancy.scope_query(Request, scope),
            where: r.company_id == ^company_id and r.status == "pending",
            order_by: [asc: r.starts_on, asc: r.id],
            limit: @queue_limit
          )
        )

      with {:ok, names} <- employee_names(scope, company_id, requests) do
        {:ok,
         Enum.map(requests, fn request ->
           request
           |> request_view()
           |> Map.put(:employee_name, Map.get(names, request.employee_id))
         end)}
      end
    end
  end

  @doc """
  Approves or rejects a pending request. The requester and the request's own
  employee cannot decide it, and a rejection needs a note. Approval rechecks
  the balance and writes the `taken` entry.
  """
  def decide(%Scope{} = scope, company_id, request_id, decision, note)
      when decision in [:approve, :reject] do
    with {:ok, note} <- optional_text(note, 500),
         true <- (decision == :approve or note != nil) || {:error, :note_required},
         {:ok, actor} <- Authorization.authorize(scope, company_id, @approve),
         {:ok, _company} <- current_company(scope, company_id),
         %Request{} = unlocked <- get_request(scope, company_id, request_id) do
      locked(scope, company_id, unlocked.employee_id, fn ->
        with %Request{status: "pending"} = request <- lock_request(scope, company_id, unlocked.id),
             :ok <- independent(scope, actor, request) do
          apply_decision(scope, company_id, actor.id, request, decision, note)
        else
          %Request{} -> {:error, :not_pending}
          error -> error
        end
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def decide(%Scope{}, _, _, _, _), do: {:error, :invalid_decision}

  defp apply_decision(scope, _company_id, actor_id, request, :reject, note),
    do: transition(scope, request, "rejected", actor_id, note)

  defp apply_decision(scope, company_id, actor_id, request, :approve, note) do
    with {:ok, _employee} <- current_employee(scope, company_id, request.employee_id),
         %LeaveType{} = type <- active_type(scope, company_id, request.leave_type_id),
         false <-
           CarryForward.closed?(
             scope,
             company_id,
             request.employee_id,
             type.id,
             request.leave_year
           ),
         :ok <- covered(scope, type, request, request.id),
         {:ok, _entry} <-
           write_entry(scope, request, "taken", Decimal.negate(request.quantity), actor_id) do
      transition(scope, request, "approved", actor_id, note)
    else
      nil -> {:error, :leave_type_unavailable}
      true -> {:error, :year_closed}
      {:error, :not_current} -> {:error, :employee_unavailable}
      error -> error
    end
  end

  defp independent(scope, %{type: :user, id: user_id} = actor, request) do
    with {:ok, user} <- User.get_user(scope, actor.company_id, user_id),
         false <- user_id == request.requested_by_user_id,
         false <- user.employee_id == request.employee_id do
      :ok
    else
      _ -> {:error, :self_approval}
    end
  end

  defp independent(_scope, _actor, _request), do: {:error, :self_approval}

  ## Balance reservation

  @doc false
  def pending_totals(scope, company_id, employee_id, leave_year) do
    Repo.all(
      from(r in Tenancy.scope_query(Request, scope),
        where:
          r.company_id == ^company_id and r.employee_id == ^employee_id and
            r.leave_year == ^leave_year and r.status == "pending",
        group_by: r.leave_type_id,
        select: {r.leave_type_id, sum(r.quantity)}
      )
    )
    |> Map.new()
  end

  @doc false
  def pending_exists?(scope, company_id, type_id, employee_id, leave_year) do
    Repo.exists?(
      from(r in Tenancy.scope_query(Request, scope),
        where:
          r.company_id == ^company_id and r.employee_id == ^employee_id and
            r.leave_type_id == ^type_id and r.leave_year == ^leave_year and
            r.status == "pending"
      )
    )
  end

  # The ledger balance less other pending requests must cover the quantity,
  # unless the type allows a negative balance.
  defp covered(_scope, %LeaveType{balance_required: false}, _request, _except_id), do: :ok

  defp covered(scope, type, request, except_id) do
    ledger =
      Repo.one(
        from(e in Tenancy.scope_query(LedgerEntry, scope),
          where:
            e.company_id == ^request.company_id and e.employee_id == ^request.employee_id and
              e.leave_type_id == ^type.id and e.leave_year == ^request.leave_year,
          select: coalesce(sum(e.quantity), 0)
        )
      )

    reserved =
      Repo.one(
        from(r in Tenancy.scope_query(Request, scope),
          where:
            r.company_id == ^request.company_id and r.employee_id == ^request.employee_id and
              r.leave_type_id == ^type.id and r.leave_year == ^request.leave_year and
              r.status == "pending" and r.id != ^except_id,
          select: coalesce(sum(r.quantity), 0)
        )
      )

    available = Decimal.sub(Decimal.new(ledger), Decimal.new(reserved))

    if Decimal.compare(available, request.quantity) == :lt,
      do: {:error, :insufficient_balance},
      else: :ok
  end

  ## Submission

  defp normalize_request(attrs) do
    with type_id when is_integer(type_id) <- field(attrs, :leave_type_id),
         {:ok, starts_on} <- parse_date(field(attrs, :starts_on)),
         {:ok, ends_on} <- parse_date(field(attrs, :ends_on) || field(attrs, :starts_on)),
         day_part when day_part in ~w(full am pm hours) <- field(attrs, :day_part) || "full",
         {:ok, hours} <- parse_hours(day_part, field(attrs, :hours)),
         {:ok, reason} <- optional_text(field(attrs, :reason), 500),
         key when is_binary(key) and byte_size(key) in 1..160 <- field(attrs, :request_key),
         :gt <- Date.compare(Date.add(starts_on, @max_span_days), ends_on),
         true <- Date.compare(ends_on, starts_on) != :lt,
         true <- day_part == "full" or starts_on == ends_on do
      {:ok,
       %{
         leave_type_id: type_id,
         starts_on: starts_on,
         ends_on: ends_on,
         day_part: day_part,
         hours: hours,
         reason: reason,
         request_key: key
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp parse_hours("hours", value) do
    case parse_quantity(value) do
      {:ok, hours} ->
        if Decimal.gt?(hours, 0) and not Decimal.gt?(hours, @max_hours),
          do: {:ok, hours},
          else: {:error, :invalid_request}

      error ->
        error
    end
  end

  defp parse_hours(_day_part, _value), do: {:ok, nil}

  defp insert_request(scope, company_id, employee_id, user_id, input) do
    with %LeaveType{} = type <-
           active_type(scope, company_id, input.leave_type_id) || {:error, :not_found},
         true <- unit_matches?(type, input) || {:error, :invalid_request},
         {:ok, rules} <- Leave.rules(scope, company_id),
         {:ok, request_rules} <- request_rules(scope, company_id),
         {:ok, today} <- Leave.today(scope, company_id),
         year = Leave.leave_year(rules, input.starts_on),
         true <- Leave.leave_year(rules, input.ends_on) == year || {:error, :spans_leave_years},
         true <-
           Date.compare(input.starts_on, Date.add(today, -request_rules.backdate_days)) != :lt ||
             {:error, :too_far_back},
         :ok <- open_year(scope, company_id, employee_id, type.id, year),
         {:ok, days} <- counted_days(scope, company_id, request_rules, input),
         :ok <- no_overlap(scope, company_id, employee_id, days) do
      quantity = Enum.reduce(days, Decimal.new("0.00"), &Decimal.add(&1.quantity, &2))

      request = %Request{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        employee_id: employee_id,
        leave_type_id: type.id,
        leave_year: year,
        starts_on: input.starts_on,
        ends_on: input.ends_on,
        day_part: input.day_part,
        quantity: quantity,
        unit: type.unit,
        status: "pending",
        reason: input.reason,
        request_key: input.request_key,
        requested_by_user_id: user_id
      }

      with :ok <- covered(scope, type, request, 0),
           {:ok, saved} <- Repo.insert(request),
           {_count, _} <- Repo.insert_all(RequestDay, day_rows(saved, days)),
           {:ok, _event} <- record_event(saved, nil, user_id, nil) do
        {:ok, request_view(saved)}
      end
    end
  end

  defp open_year(scope, company_id, employee_id, type_id, year) do
    if CarryForward.closed?(scope, company_id, employee_id, type_id, year),
      do: {:error, :year_closed},
      else: :ok
  end

  defp unit_matches?(%LeaveType{unit: "hour"}, %{day_part: "hours"}), do: true
  defp unit_matches?(%LeaveType{unit: "day"}, %{day_part: part}), do: part != "hours"
  defp unit_matches?(_type, _input), do: false

  # Dates in range on the company's working weekdays that are not calendar
  # exceptions, each with the half-day slots and quantity the request holds.
  defp counted_days(scope, company_id, rules, input) do
    with {:ok, exceptions} <- ReferenceData.list_calendar_exceptions(scope, company_id) do
      closed = MapSet.new(exceptions, & &1.on_date)

      days =
        for date <- Date.range(input.starts_on, input.ends_on),
            Date.day_of_week(date) in rules.working_weekdays,
            not MapSet.member?(closed, date) do
          case input.day_part do
            "full" -> %{on_date: date, am: true, pm: true, quantity: Decimal.new("1.00")}
            "am" -> %{on_date: date, am: true, pm: false, quantity: Decimal.new("0.50")}
            "pm" -> %{on_date: date, am: false, pm: true, quantity: Decimal.new("0.50")}
            "hours" -> %{on_date: date, am: true, pm: true, quantity: input.hours}
          end
        end

      if days == [], do: {:error, :no_working_days}, else: {:ok, days}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp no_overlap(scope, company_id, employee_id, days) do
    dates = Enum.map(days, & &1.on_date)

    taken =
      Repo.all(
        from(d in Tenancy.scope_query(RequestDay, scope),
          where:
            d.company_id == ^company_id and d.employee_id == ^employee_id and d.active and
              d.on_date in ^dates,
          select: {d.on_date, d.am, d.pm}
        )
      )
      |> Enum.group_by(&elem(&1, 0))

    clash? =
      Enum.any?(days, fn day ->
        Enum.any?(Map.get(taken, day.on_date, []), fn {_, am, pm} ->
          (am and day.am) or (pm and day.pm)
        end)
      end)

    if clash?, do: {:error, :overlapping_request}, else: :ok
  end

  defp day_rows(request, days) do
    Enum.map(days, fn day ->
      Map.merge(day, %{
        tenant_id: request.tenant_id,
        company_id: request.company_id,
        employee_id: request.employee_id,
        request_id: request.id,
        active: true
      })
    end)
  end

  defp replay(existing, input) do
    same? =
      existing.leave_type_id == input.leave_type_id and existing.starts_on == input.starts_on and
        existing.ends_on == input.ends_on and existing.day_part == input.day_part and
        (input.hours == nil or Decimal.equal?(existing.quantity, input.hours)) and
        existing.reason == input.reason

    if same?, do: {:ok, request_view(existing)}, else: {:error, :request_key_conflict}
  end

  ## Transitions and ledger

  defp transition(scope, request, to_status, actor_id, note) do
    now = DateTime.utc_now()

    changes =
      case to_status do
        "cancelled" ->
          [status: to_status, cancelled_by_user_id: actor_id, cancelled_at: now]

        _ ->
          [status: to_status, decided_by_user_id: actor_id, decided_at: now, decision_note: note]
      end

    with {:ok, updated} <- request |> Ecto.Changeset.change(changes) |> Repo.update(),
         :ok <- release_days(scope, updated),
         {:ok, _event} <- record_event(updated, request.status, actor_id, note) do
      {:ok, request_view(updated)}
    end
  end

  # Only a live request holds its slots.
  defp release_days(_scope, %Request{status: status}) when status in ~w(pending approved),
    do: :ok

  defp release_days(scope, request) do
    from(d in Tenancy.scope_query(RequestDay, scope), where: d.request_id == ^request.id)
    |> Repo.update_all(set: [active: false])

    :ok
  end

  defp write_entry(scope, request, entry_type, quantity, actor_id) do
    %LedgerEntry{
      tenant_id: Scope.tenant_id(scope),
      company_id: request.company_id,
      employee_id: request.employee_id,
      leave_type_id: request.leave_type_id
    }
    |> LedgerEntry.changeset(%{
      leave_year: request.leave_year,
      entry_type: entry_type,
      quantity: quantity,
      unit: request.unit,
      occurred_on: request.starts_on,
      source: @request_source,
      entry_key: "#{entry_type}:#{request.id}",
      actor_user_id: actor_id
    })
    |> Repo.insert()
  end

  defp record_event(request, from_status, actor_id, note) do
    Repo.insert(%RequestEvent{
      tenant_id: request.tenant_id,
      company_id: request.company_id,
      request_id: request.id,
      from_status: from_status,
      to_status: request.status,
      actor_user_id: actor_id,
      note: note,
      occurred_at: DateTime.utc_now()
    })
  end

  ## Reads and locks

  defp locked(scope, company_id, employee_id, fun) do
    Repo.transaction(fn ->
      with {:ok, _proof} <- Employee.lock_affiliation(scope, company_id, employee_id),
           {:ok, value} <- fun.() do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp find_by_key(scope, company_id, employee_id, key),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(Request, scope),
          where:
            r.company_id == ^company_id and r.employee_id == ^employee_id and
              r.request_key == ^key
        )
      )

  defp get_request(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(Request, scope),
          where: r.company_id == ^company_id and r.id == ^id
        )
      )

  defp get_request(_, _, _), do: nil

  defp lock_request(scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(Request, scope),
          where: r.company_id == ^company_id and r.id == ^id,
          lock: "FOR UPDATE"
        )
      )

  defp lock_request(_, _, _), do: nil

  defp active_type(scope, company_id, type_id) when is_integer(type_id),
    do:
      Repo.one(
        from(t in Tenancy.scope_query(LeaveType, scope),
          where: t.company_id == ^company_id and t.id == ^type_id and t.status == "active",
          lock: "FOR SHARE"
        )
      )

  defp active_type(_, _, _), do: nil

  defp employee_names(_scope, _company_id, []), do: {:ok, %{}}

  defp employee_names(scope, company_id, requests) do
    ids = requests |> Enum.map(& &1.employee_id) |> Enum.uniq()

    with {:ok, read} <- Workforce.employees_by_ids(scope, company_id, ids),
         {:ok, employees} <- ReadResult.require_current(read) do
      {:ok,
       Map.new(employees, fn employee ->
         {String.to_integer(employee.reference.stable_id),
          "#{employee.display_name} (#{employee.employee_number})"}
       end)}
    end
  end

  defp current_company(scope, company_id) do
    with {:ok, read} <- Workforce.company(scope, company_id),
         do: ReadResult.require_current(read)
  end

  defp current_employee(scope, company_id, employee_id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, employee_id),
         do: ReadResult.require_current(read)
  end

  defp settings_scope(scope, company),
    do: SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp request_view(request), do: Map.take(request, @request_fields)
end
