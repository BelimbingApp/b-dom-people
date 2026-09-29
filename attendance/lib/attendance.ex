defmodule Bilimbi.People.Attendance do
  @moduledoc "Company-scoped clock facts and day projections."
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.User
  alias Bilimbi.People.Attendance.{ClockEvent, Day}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @timezone_key "people.attendance.timezone"
  @self_clock_key "people.attendance.self_clock_enabled"

  def rules(%Scope{} = scope, company_id) do
    with {:ok, company} <- current_company(scope, company_id) do
      settings_scope = SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

      {:ok,
       %{
         timezone: Settings.get(@timezone_key, settings_scope),
         self_clock_enabled: Settings.get(@self_clock_key, settings_scope)
       }}
    end
  end

  def put_rules(%Scope{} = scope, company_id, timezone, enabled)
      when is_binary(timezone) and is_boolean(enabled) do
    with {:ok, company} <- current_company(scope, company_id),
         {:ok, _} <- local_date(DateTime.utc_now(), timezone) do
      settings_scope = SettingsScope.company(company.platform_company_id, Scope.tenant_id(scope))

      with {:ok, _} <- Settings.put(@timezone_key, timezone, settings_scope),
           {:ok, _} <- Settings.put(@self_clock_key, enabled, settings_scope) do
        rules(scope, company_id)
      end
    end
  end

  def put_rules(%Scope{}, _, _, _), do: {:error, :invalid_rules}

  @doc "Idempotent by company, source and key; conflicting replays are refused."
  def record_clock(%Scope{} = scope, company_id, employee_id, attrs) when is_map(attrs) do
    with {:ok, _employee} <- current_employee(scope, company_id, employee_id),
         {:ok, %{timezone: timezone}} <- rules(scope, company_id),
         {:ok, event} <- normalize_event(attrs, timezone) do
      Repo.transaction(fn -> write_event(scope, company_id, employee_id, event) end)
    end
  end

  def self_clock(%Scope{} = scope, company_id, actor, type, key)
      when type in ["in", "out"] and is_binary(key) do
    with {:ok, employee_id} <- self_employee(scope, company_id, actor),
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
    with {:ok, employee_id} <- self_employee(scope, company_id, actor) do
      list_days(scope, company_id, employee_id)
    end
  end

  def list_days(%Scope{} = scope, company_id, employee_id) do
    with {:ok, _employee} <- current_employee(scope, company_id, employee_id) do
      {:ok,
       Repo.all(
         from(d in Tenancy.scope_query(Day, scope),
           where: d.company_id == ^company_id and d.employee_id == ^employee_id,
           order_by: [desc: d.on_date],
           limit: 31
         )
       )
       |> Enum.map(&day_view/1)}
    end
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

  defp current_company(scope, company_id) do
    with {:ok, read} <- Workforce.company(scope, company_id),
         do: ReadResult.require_current(read)
  end

  defp current_employee(scope, company_id, employee_id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, employee_id),
         do: ReadResult.require_current(read)
  end

  defp normalize_event(attrs, timezone) do
    key = Map.get(attrs, :event_key) || Map.get(attrs, "event_key")
    type = Map.get(attrs, :event_type) || Map.get(attrs, "event_type")
    source = Map.get(attrs, :source) || Map.get(attrs, "source")
    occurred_at = Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at")
    actor_user_id = Map.get(attrs, :actor_user_id) || Map.get(attrs, "actor_user_id")

    with true <- is_binary(key) and byte_size(key) in 1..160,
         true <- type in ~w(in out break_in break_out),
         true <- is_binary(source) and byte_size(source) in 1..32,
         true <- match?(%DateTime{}, occurred_at),
         {:ok, date} <- local_date(occurred_at, timezone) do
      {:ok,
       %{
         event_key: key,
         event_type: type,
         source: source,
         occurred_at: DateTime.truncate(occurred_at, :second),
         timezone: timezone,
         actor_user_id: actor_user_id,
         on_date: date
       }}
    else
      _ -> {:error, :invalid_event}
    end
  end

  defp local_date(at, timezone) when is_binary(timezone) do
    case BaseDateTime.shift(at, timezone) do
      {:ok, local} -> {:ok, DateTime.to_date(local)}
      _ -> {:error, :invalid_timezone}
    end
  end

  defp local_date(_, _), do: {:error, :invalid_timezone}

  defp write_event(scope, company_id, employee_id, event) do
    case find_event(scope, company_id, event) do
      nil ->
        day = get_or_create_day(scope, company_id, employee_id, event.on_date)

        case find_event(scope, company_id, event) do
          nil -> insert_event(scope, day, event)
          existing -> replay_event(existing, employee_id, event)
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

  defp insert_event(scope, day, event) do
    %ClockEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: day.company_id,
      employee_id: day.employee_id,
      day_id: day.id
    }
    |> ClockEvent.changeset(Map.delete(event, :on_date))
    |> Repo.insert()
    |> case do
      {:ok, saved} ->
        project_day(scope, day)
        event_view(saved)

      {:error, changeset} ->
        if Enum.any?(changeset.errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end),
          do: Repo.rollback(:event_key_conflict),
          else: Repo.rollback(:invalid_event)
    end
  end

  defp get_or_create_day(scope, company_id, employee_id, date) do
    query =
      from(d in Tenancy.scope_query(Day, scope),
        where:
          d.company_id == ^company_id and d.employee_id == ^employee_id and d.on_date == ^date
      )

    with nil <- Repo.one(lock(query, "FOR UPDATE")) do
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
        {:error, _changeset} -> Repo.one!(lock(query, "FOR UPDATE"))
      end
    end
  end

  defp project_day(scope, day) do
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
      first_in && last_out &&
        DateTime.compare(last_out.occurred_at, first_in.occurred_at) == :gt

    minutes =
      if complete?,
        do: div(DateTime.diff(last_out.occurred_at, first_in.occurred_at), 60),
        else: 0

    status = if complete?, do: "ready_for_review", else: "exception_pending"

    day
    |> Day.changeset(%{
      status: status,
      first_in_at: first_in && first_in.occurred_at,
      last_out_at: last_out && last_out.occurred_at,
      worked_minutes: minutes
    })
    |> Repo.update!()
  end

  defp day_view(day),
    do: Map.take(day, [:on_date, :status, :first_in_at, :last_out_at, :worked_minutes])

  defp event_view(event),
    do: Map.take(event, [:id, :event_type, :occurred_at, :timezone, :source])
end
