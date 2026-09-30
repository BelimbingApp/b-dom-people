defmodule Bilimbi.People.Attendance do
  @moduledoc """
  Company-scoped clock facts, day projections, rosters, clocking locations and
  attendance adjustments.

  Every function takes a validated `Bilimbi.Base.Tenancy.Scope` and an explicit
  platform company ID; employees are read through `people/workforce`.
  """
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope

  alias Bilimbi.People.Attendance.{
    Access,
    Adjustments,
    Allowances,
    ClockEvent,
    Day,
    Locations,
    Rosters
  }

  @timezone_key "people.attendance.timezone"
  @self_clock_key "people.attendance.self_clock_enabled"
  @max_shift_key "people.attendance.max_shift_hours"
  @location_key "people.attendance.location_required"
  @adjustment_window_key "people.attendance.adjustment_window_days"

  @rule_keys %{
    timezone: @timezone_key,
    self_clock_enabled: @self_clock_key,
    max_shift_hours: @max_shift_key,
    location_required: @location_key,
    adjustment_window_days: @adjustment_window_key
  }

  def rules(%Scope{} = scope, company_id) do
    with {:ok, company} <- Access.current_company(scope, company_id) do
      settings_scope = Access.settings_scope(scope, company)
      {:ok, Map.new(@rule_keys, fn {name, key} -> {name, Settings.get(key, settings_scope)} end)}
    end
  end

  def put_rules(%Scope{} = scope, company_id, timezone, enabled, max_shift_hours),
    do:
      put_rules(scope, company_id, %{
        timezone: timezone,
        self_clock_enabled: enabled,
        max_shift_hours: max_shift_hours
      })

  @doc "Stores the given company rules; omitted rules keep their current value."
  def put_rules(%Scope{} = scope, company_id, %{} = changes) do
    with :ok <- validate_rules(changes),
         {:ok, company} <- Access.current_company(scope, company_id) do
      settings_scope = Access.settings_scope(scope, company)

      changes
      |> Enum.reduce_while(:ok, fn {name, value}, :ok ->
        case Settings.put(Map.fetch!(@rule_keys, name), value, settings_scope) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> rules(scope, company_id)
        error -> error
      end
    end
  end

  def put_rules(%Scope{}, _, _), do: {:error, :invalid_rules}

  defp validate_rules(changes) do
    if Enum.all?(changes, fn {name, value} -> valid_rule?(name, value) end),
      do: :ok,
      else: {:error, :invalid_rules}
  end

  defp valid_rule?(:timezone, value),
    do: is_binary(value) and match?({:ok, _}, local_date(DateTime.utc_now(), value))

  defp valid_rule?(:self_clock_enabled, value), do: is_boolean(value)
  defp valid_rule?(:location_required, value), do: is_boolean(value)
  defp valid_rule?(:max_shift_hours, value), do: value in 1..24
  defp valid_rule?(:adjustment_window_days, value), do: value in 1..366
  defp valid_rule?(_, _), do: false

  @doc "Idempotent by company, source and key; conflicting replays are refused."
  def record_clock(%Scope{} = scope, company_id, employee_id, attrs) when is_map(attrs) do
    with {:ok, _employee} <- Access.current_employee(scope, company_id, employee_id),
         {:ok, rules} <- rules(scope, company_id),
         {:ok, event} <- normalize_event(attrs, rules.timezone),
         {:ok, event} <- place_event(scope, company_id, event, rules.location_required) do
      Repo.transaction(fn ->
        write_event(scope, company_id, employee_id, event, rules.max_shift_hours)
      end)
    end
  end

  @doc false
  # Adjustments call this inside their own transaction after an approver's
  # decision; the approval, not a location, is the event's evidence.
  def record_approved_adjustment(%Scope{} = scope, company_id, employee_id, attrs) do
    with {:ok, rules} <- rules(scope, company_id),
         {:ok, event} <- normalize_event(attrs, rules.timezone) do
      event = Map.merge(event, %{latitude: nil, longitude: nil, clocking_location_id: nil})

      Repo.transaction(fn ->
        write_event(scope, company_id, employee_id, event, rules.max_shift_hours)
      end)
    end
  end

  defp place_event(_scope, _company_id, %{latitude: nil} = event, location_required) do
    if location_required,
      do: {:error, :location_required},
      else: {:ok, Map.put(event, :clocking_location_id, nil)}
  end

  defp place_event(scope, company_id, event, location_required) do
    case Locations.locate(scope, company_id, event.latitude, event.longitude) do
      {:ok, location} ->
        {:ok, Map.put(event, :clocking_location_id, location.id)}

      :none when location_required ->
        {:error, :outside_clocking_location}

      :none ->
        {:ok, Map.put(event, :clocking_location_id, nil)}
    end
  end

  def self_clock(%Scope{} = scope, company_id, actor, type, key)
      when type in ["in", "out"] and is_binary(key) do
    with {:ok, employee_id} <- Access.self_employee(scope, company_id, actor),
         {:ok, %{self_clock_enabled: true}} <- rules(scope, company_id) do
      record_clock(scope, company_id, employee_id, %{
        event_key: key,
        event_type: type,
        source: "web",
        occurred_at: DateTime.utc_now(),
        actor_user_id: actor.id
      })
    else
      _ -> {:error, :unavailable}
    end
  end

  def self_clock(%Scope{}, _, _, _, _), do: {:error, :invalid_event}

  def self_days(%Scope{} = scope, company_id, actor) do
    with {:ok, employee_id} <- Access.self_employee(scope, company_id, actor) do
      list_days(scope, company_id, employee_id)
    end
  end

  def list_days(%Scope{} = scope, company_id, employee_id) do
    with {:ok, _employee} <- Access.current_employee(scope, company_id, employee_id),
         {:ok, %{max_shift_hours: max_shift_hours}} <- rules(scope, company_id) do
      now = DateTime.utc_now()

      {:ok,
       Repo.all(
         from(d in Tenancy.scope_query(Day, scope),
           where: d.company_id == ^company_id and d.employee_id == ^employee_id,
           order_by: [desc: d.on_date],
           limit: 31
         )
       )
       |> Enum.map(&day_view(&1, max_shift_hours, now))}
    end
  end

  defp normalize_event(attrs, timezone) do
    key = Map.get(attrs, :event_key) || Map.get(attrs, "event_key")
    type = Map.get(attrs, :event_type) || Map.get(attrs, "event_type")
    source = Map.get(attrs, :source) || Map.get(attrs, "source")
    occurred_at = Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at")
    actor_user_id = Map.get(attrs, :actor_user_id) || Map.get(attrs, "actor_user_id")
    latitude = Map.get(attrs, :latitude) || Map.get(attrs, "latitude")
    longitude = Map.get(attrs, :longitude) || Map.get(attrs, "longitude")

    with true <- is_binary(key) and byte_size(key) in 1..160,
         true <- type in ~w(in out break_in break_out),
         true <- is_binary(source) and byte_size(source) in 1..32,
         true <- match?(%DateTime{}, occurred_at),
         {:ok, point} <- point(latitude, longitude),
         {:ok, date} <- local_date(occurred_at, timezone) do
      {:ok,
       %{
         event_key: key,
         event_type: type,
         source: source,
         occurred_at: DateTime.truncate(occurred_at, :second),
         timezone: timezone,
         actor_user_id: actor_user_id,
         latitude: elem(point, 0),
         longitude: elem(point, 1),
         on_date: date
       }}
    else
      _ -> {:error, :invalid_event}
    end
  end

  defp point(nil, nil), do: {:ok, {nil, nil}}

  defp point(latitude, longitude) do
    with {:ok, lat} <- coordinate(latitude, 90),
         {:ok, lon} <- coordinate(longitude, 180),
         do: {:ok, {lat, lon}}
  end

  defp coordinate(value, bound) when is_number(value),
    do: coordinate(Decimal.from_float(value * 1.0), bound)

  defp coordinate(%Decimal{} = value, bound) do
    if Decimal.compare(Decimal.abs(value), bound) == :gt,
      do: :error,
      else: {:ok, Decimal.round(value, 6)}
  end

  defp coordinate(_, _), do: :error

  @doc false
  def local_date(at, timezone) when is_binary(timezone) do
    case BaseDateTime.shift(at, timezone) do
      {:ok, local} -> {:ok, DateTime.to_date(local)}
      _ -> {:error, :invalid_timezone}
    end
  end

  def local_date(_, _), do: {:error, :invalid_timezone}

  defp write_event(scope, company_id, employee_id, event, max_shift_hours) do
    case find_event(scope, company_id, event) do
      nil ->
        target = shift_day(scope, company_id, employee_id, event, max_shift_hours)

        case find_event(scope, company_id, event) do
          nil ->
            day =
              with {:create, date} <- target,
                   do: get_or_create_day(scope, company_id, employee_id, date)

            insert_event(scope, day, event, max_shift_hours)

          existing ->
            replay_event(existing, employee_id, event)
        end

      existing ->
        replay_event(existing, employee_id, event)
    end
  end

  defp find_event(scope, company_id, event) do
    Repo.one(
      from(e in Tenancy.scope_query(ClockEvent, scope),
        where:
          e.company_id == ^company_id and e.source == ^event.source and
            e.event_key == ^event.event_key
      )
    )
  end

  defp replay_event(existing, employee_id, event) do
    if existing.employee_id == employee_id and existing.event_type == event.event_type and
         existing.occurred_at == event.occurred_at and
         existing.actor_user_id == event.actor_user_id,
       do: event_view(existing),
       else: Repo.rollback(:event_key_conflict)
  end

  defp insert_event(scope, day, event, max_shift_hours) do
    %ClockEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: day.company_id,
      employee_id: day.employee_id,
      day_id: day.id
    }
    |> ClockEvent.changeset(Map.delete(event, :on_date))
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, saved} ->
        project_day(scope, day, max_shift_hours)
        event_view(saved)

      {:error, changeset} ->
        if Enum.any?(changeset.errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end) do
          case find_event(scope, day.company_id, event) do
            nil -> Repo.rollback(:event_key_conflict)
            existing -> replay_event(existing, day.employee_id, event)
          end
        else
          Repo.rollback(:invalid_event)
        end
    end
  end

  defp shift_day(scope, company_id, employee_id, %{event_type: "in"} = event, _),
    do: locked_day(scope, company_id, employee_id, event.on_date) || {:create, event.on_date}

  defp shift_day(scope, company_id, employee_id, event, max_shift_hours) do
    today = locked_day(scope, company_id, employee_id, event.on_date)

    if open_shift?(today) do
      today
    else
      previous = locked_day(scope, company_id, employee_id, Date.add(event.on_date, -1))

      if open_shift?(previous) and
           DateTime.compare(event.occurred_at, previous.first_in_at) != :lt and
           DateTime.diff(event.occurred_at, previous.first_in_at) <= max_shift_hours * 3600,
         do: previous,
         else: today || {:create, event.on_date}
    end
  end

  defp open_shift?(%Day{status: "in_progress", first_in_at: %DateTime{}}), do: true
  defp open_shift?(_), do: false

  defp locked_day(scope, company_id, employee_id, date) do
    Repo.one(
      from(d in Tenancy.scope_query(Day, scope),
        where:
          d.company_id == ^company_id and d.employee_id == ^employee_id and d.on_date == ^date,
        lock: "FOR UPDATE"
      )
    )
  end

  defp get_or_create_day(scope, company_id, employee_id, date) do
    with nil <- locked_day(scope, company_id, employee_id, date) do
      # A savepoint keeps a concurrent first insert from aborting the
      # transaction; the loser then waits on the winner's row lock.
      %Day{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        employee_id: employee_id,
        on_date: date
      }
      |> Day.changeset(%{status: "in_progress"})
      |> Repo.insert(mode: :savepoint)
      |> case do
        {:ok, day} -> day
        {:error, _changeset} -> locked_day(scope, company_id, employee_id, date)
      end
    end
  end

  defp project_day(scope, day, max_shift_hours) do
    events =
      Repo.all(
        from(e in Tenancy.scope_query(ClockEvent, scope),
          where: e.day_id == ^day.id and e.company_id == ^day.company_id,
          order_by: [asc: e.occurred_at, asc: e.id]
        )
      )

    first_in = Enum.find(events, &(&1.event_type == "in"))
    last_out = Enum.find(Enum.reverse(events), &(&1.event_type == "out"))

    complete? =
      !!(first_in && last_out &&
           DateTime.compare(last_out.occurred_at, first_in.occurred_at) == :gt &&
           DateTime.diff(last_out.occurred_at, first_in.occurred_at) <= max_shift_hours * 3600)

    minutes =
      if complete?,
        do: div(DateTime.diff(last_out.occurred_at, first_in.occurred_at), 60),
        else: 0

    status =
      cond do
        complete? -> "ready_for_review"
        first_in && is_nil(last_out) -> "in_progress"
        true -> "exception_pending"
      end

    day
    |> Day.changeset(%{
      status: status,
      first_in_at: first_in && first_in.occurred_at,
      last_out_at: last_out && last_out.occurred_at,
      worked_minutes: minutes
    })
    |> Repo.update!()
  end

  defp day_view(day, max_shift_hours, now) do
    view = Map.take(day, [:on_date, :status, :first_in_at, :last_out_at, :worked_minutes])

    if open_shift?(day) and DateTime.diff(now, day.first_in_at) > max_shift_hours * 3600,
      do: %{view | status: "exception_pending"},
      else: view
  end

  defp event_view(event),
    do: Map.take(event, [:id, :event_type, :occurred_at, :timezone, :source])

  # Shift templates, clocking locations, rosters and adjustments. See
  # `docs/README.md` for their workflow and refusals.
  defdelegate list_shift_templates(scope, company_id), to: Rosters
  defdelegate create_shift_template(scope, company_id, attrs), to: Rosters
  defdelegate set_shift_template_status(scope, company_id, template_id, status), to: Rosters
  defdelegate roster(scope, company_id, from, days, options \\ []), to: Rosters

  defdelegate plan_roster_entry(scope, company_id, actor, employee_id, on_date, value),
    to: Rosters

  defdelegate publish_roster(scope, company_id, actor, from, to), to: Rosters
  defdelegate self_roster(scope, company_id, actor, from, days), to: Rosters

  defdelegate list_clocking_locations(scope, company_id), to: Locations
  defdelegate create_clocking_location(scope, company_id, attrs), to: Locations
  defdelegate set_clocking_location_status(scope, company_id, location_id, status), to: Locations

  defdelegate list_allowance_rules(scope, company_id), to: Allowances, as: :list
  defdelegate create_allowance_rule(scope, company_id, attrs), to: Allowances, as: :create
  defdelegate get_allowance_rule(scope, company_id, rule_id), to: Allowances, as: :get

  defdelegate retire_allowance_rule(scope, company_id, rule_id), to: Allowances, as: :retire

  defdelegate end_allowance_rule(scope, company_id, rule_id, until_date),
    to: Allowances,
    as: :end_date

  @doc "Schema-free allowance catalog values for Payroll mapping and as-of reads."
  def payroll_allowance_sources(scope, company_id, as_of \\ Date.utc_today()),
    do: Allowances.sources(scope, company_id, as_of)

  defdelegate submit_adjustment(scope, company_id, actor, attrs), to: Adjustments
  defdelegate self_adjustments(scope, company_id, actor), to: Adjustments
  defdelegate cancel_adjustment(scope, company_id, actor, request_id), to: Adjustments
  defdelegate pending_adjustments(scope, company_id), to: Adjustments

  defdelegate decide_adjustment(scope, company_id, actor, request_id, decision, note),
    to: Adjustments
end
