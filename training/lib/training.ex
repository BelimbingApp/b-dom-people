defmodule Bilimbi.People.Training do
  @moduledoc """
  Company-owned courses, delivery events and session calendar.

  Every operation receives an authenticated tenant scope and an explicit
  platform company. Workforce freshness comes from Workforce.ReadResult.
  Capacity is the maximum learners per event/session; enrollment and attendance
  belong to the participation slice. Times are entered with an explicit IANA
  zone and stored as UTC instants. DST gaps and overlaps require correction.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Authz, Repo, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Training.{Course, Event, Session}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Training.Evaluation
  defdelegate evaluation_policies(scope, company), to: Evaluation, as: :policies
  defdelegate publish_evaluation_policy(scope, company, attrs), to: Evaluation, as: :publish

  defdelegate prepare_evaluation_reviews(scope, company, session, now),
    to: Evaluation,
    as: :prepare_reviews

  defdelegate evaluation_reviews(scope, company, kind), to: Evaluation, as: :reviews
  defdelegate answer_evaluation(scope, company, id, values, reason), to: Evaluation, as: :answer
  defdelegate evaluation_reminders(scope, company, today), to: Evaluation, as: :remind
  defdelegate effectiveness_summary(scope, company, today), to: Evaluation, as: :summary

  alias Bilimbi.People.Training.Governance
  defdelegate learning_currencies(scope, company_id), to: Governance, as: :currencies

  defdelegate put_learning_currencies(scope, company_id, values),
    to: Governance,
    as: :put_currencies

  defdelegate create_budget_policy(scope, company_id, attrs), to: Governance, as: :create_budget

  defdelegate supersede_budget_policy(scope, company_id, id, attrs),
    to: Governance,
    as: :supersede_budget

  defdelegate learning_budgets(scope, company_id), to: Governance, as: :budgets

  defdelegate create_learning_request(scope, company_id, attrs),
    to: Governance,
    as: :create_request

  defdelegate learning_requests(scope, company_id, audience), to: Governance, as: :requests

  defdelegate decide_learning_request(scope, company_id, id, action, reason),
    to: Governance,
    as: :decide_request

  defdelegate create_learning_plan(scope, company_id, attrs, items),
    to: Governance,
    as: :create_plan

  defdelegate amend_learning_plan(scope, company_id, id, attrs, items),
    to: Governance,
    as: :amend_plan

  defdelegate learning_plans(scope, company_id, audience), to: Governance, as: :plans

  defdelegate decide_learning_plan(scope, company_id, id, action, reason),
    to: Governance,
    as: :decide_plan

  defdelegate learning_histories(scope, company_id, kind, ids, audience),
    to: Governance,
    as: :histories

  def allowed?(%Scope{} = scope, company_id, capability),
    do: match?({:ok, _}, authorize(scope, company_id, capability))

  def list_courses(scope, company_id) do
    with {:ok, _} <- authorize(scope, company_id, "people.training.courses.view") do
      {:ok,
       Repo.all(from(c in scoped(Course, scope, company_id), order_by: [asc: c.name, asc: c.id]))
       |> Enum.map(&view/1)}
    end
  end

  def create_course(scope, company_id, attrs) do
    with {:ok, actor} <- authorize(scope, company_id, "people.training.courses.manage") do
      new(Course, scope, company_id, actor)
      |> Course.changeset(Map.put(stringify(attrs), "active", true))
      |> Repo.insert()
      |> result()
    end
  end

  def update_course(scope, company_id, id, attrs) do
    with {:ok, actor} <- authorize(scope, company_id, "people.training.courses.manage"),
         %Course{} = course <- get(Course, scope, company_id, id) do
      course
      |> Course.changeset(Map.take(stringify(attrs), ~w(name description active)))
      |> Ecto.Changeset.change(
        actor_user_id: actor.user_id,
        impersonator_id: actor.impersonator_id
      )
      |> Repo.update()
      |> result()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def list_events(scope, company_id) do
    with {:ok, _} <- authorize(scope, company_id, "people.training.sessions.view") do
      records =
        Repo.all(
          from(e in scoped(Event, scope, company_id),
            join: course in Course,
            on: course.id == e.course_id,
            order_by: [asc: e.name, asc: e.id],
            select: {e, course.name}
          )
        )

      {:ok, Enum.map(records, fn {event, name} -> Map.put(view(event), :course_name, name) end)}
    end
  end

  def event_courses(scope, company_id) do
    with {:ok, _} <- authorize(scope, company_id, "people.training.sessions.manage") do
      {:ok,
       Repo.all(
         from(c in scoped(Course, scope, company_id),
           where: c.active,
           order_by: [asc: c.name, asc: c.id],
           select: %{id: c.id, name: c.name}
         )
       )}
    end
  end

  def create_event(scope, company_id, attrs) do
    attrs = stringify(attrs)

    with {:ok, actor} <- authorize(scope, company_id, "people.training.sessions.manage") do
      transaction(fn ->
        course = get(Course, scope, company_id, integer(attrs["course_id"]), true)
        if is_nil(course) or not course.active, do: Repo.rollback(:course_unavailable)
        new(Event, scope, company_id, actor) |> Event.changeset(attrs) |> Repo.insert()
      end)
    end
  end

  def create_session(scope, company_id, attrs) do
    attrs = stringify(attrs)

    with {:ok, actor} <- authorize(scope, company_id, "people.training.sessions.manage"),
         {:ok, starts_at} <- local_instant(attrs["starts_local"], attrs["time_zone"]),
         {:ok, ends_at} <- local_instant(attrs["ends_local"], attrs["time_zone"]),
         true <- DateTime.compare(ends_at, starts_at) == :gt do
      transaction(fn ->
        event = get(Event, scope, company_id, integer(attrs["event_id"]), true)
        if is_nil(event), do: Repo.rollback(:event_unavailable)
        capacity = integer(attrs["capacity"])

        if is_integer(capacity) and capacity > event.capacity,
          do: Repo.rollback(:capacity_exceeded)

        attrs = Map.merge(attrs, %{"starts_at" => starts_at, "ends_at" => ends_at})
        new(Session, scope, company_id, actor) |> Session.changeset(attrs) |> Repo.insert()
      end)
    else
      false -> {:error, :invalid_time_range}
      error -> error
    end
  end

  @doc "Sessions overlapping the half-open UTC window, ordered by instant, bounded to 500."
  def calendar(scope, company_id, %DateTime{} = from, %DateTime{} = until) do
    with {:ok, _} <- authorize(scope, company_id, "people.training.sessions.view"),
         true <-
           DateTime.compare(until, from) == :gt and DateTime.diff(until, from) <= 366 * 86_400 do
      {:ok,
       Repo.all(
         from(s in scoped(Session, scope, company_id),
           where: s.starts_at < ^until and s.ends_at > ^from,
           order_by: [asc: s.starts_at, asc: s.id],
           limit: 500
         )
       )
       |> Enum.map(&view/1)}
    else
      false -> {:error, :invalid_calendar_range}
      error -> error
    end
  end

  @doc "Converts a local wall clock and named zone, refusing ambiguous and nonexistent times."
  def local_instant(local, zone) when is_binary(local) and is_binary(zone) do
    local = if byte_size(local) == 16, do: local <> ":00", else: local

    with {:ok, naive} <- NaiveDateTime.from_iso8601(local),
         {:ok, date_time} <-
           DateTime.from_naive(naive, zone, Bilimbi.Base.DateTime.time_zone_database()),
         {:ok, utc} <-
           DateTime.shift_zone(date_time, "Etc/UTC", Bilimbi.Base.DateTime.time_zone_database()) do
      {:ok, DateTime.truncate(utc, :second)}
    else
      {:ambiguous, _, _} -> {:error, :ambiguous_time}
      {:gap, _, _} -> {:error, :nonexistent_time}
      _ -> {:error, :invalid_time_zone_or_time}
    end
  end

  def local_instant(_, _), do: {:error, :invalid_time_zone_or_time}

  @doc "First UTC instant of a local calendar day, resolving midnight DST gaps and overlaps."
  def day_start(%Date{} = date, zone) when is_binary(zone) do
    case DateTime.new(date, ~T[00:00:00], zone, Bilimbi.Base.DateTime.time_zone_database()) do
      {:ok, date_time} -> to_utc(date_time)
      {:ambiguous, first, _} -> to_utc(first)
      {:gap, _, first_after} -> to_utc(first_after)
      _ -> {:error, :invalid_time_zone_or_time}
    end
  end

  defp to_utc(date_time) do
    case DateTime.shift_zone(date_time, "Etc/UTC", Bilimbi.Base.DateTime.time_zone_database()) do
      {:ok, utc} -> {:ok, DateTime.truncate(utc, :second)}
      _ -> {:error, :invalid_time_zone_or_time}
    end
  end

  def authorize(%Scope{} = scope, company_id, capability)
      when is_integer(company_id) and company_id > 0 and company_id <= 9_223_372_036_854_775_807 do
    actor = Scope.actor(scope)

    with true <- actor.type == :user,
         true <- Authz.can(scope, capability).allowed,
         true <-
           actor.company_id == company_id or
             Authz.can(scope, "admin.company.tenant-wide.manage").allowed,
         {:ok, %{status: "active"}} <- Company.get_company(scope, company_id),
         {:ok, read} <- Workforce.company(scope, company_id),
         {:ok, _company} <- ReadResult.require_current(read) do
      {:ok, actor}
    else
      false -> {:error, :unauthorized}
      {:ok, _} -> {:error, :company_unavailable}
      error -> error
    end
  end

  def authorize(%Scope{}, _company_id, _capability), do: {:error, :not_found}

  defp scoped(schema, scope, company_id),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company_id)

  defp get(schema, scope, company_id, id, lock \\ false)
  defp get(_, _, _, nil, _lock), do: nil

  defp get(schema, scope, company_id, id, lock) do
    case integer(id) do
      nil ->
        nil

      id ->
        query = from(r in scoped(schema, scope, company_id), where: r.id == ^id)
        Repo.one(if lock, do: from(r in query, lock: "FOR UPDATE"), else: query)
    end
  end

  defp new(schema, scope, company_id, actor),
    do:
      struct(schema,
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        actor_user_id: actor.user_id,
        impersonator_id: actor.impersonator_id
      )

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, record} -> view(record)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp result({:ok, record}), do: {:ok, view(record)}
  defp result(error), do: error
  defp view(record), do: record |> Map.from_struct() |> Map.drop([:__meta__])
  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp integer(value) when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
    do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> integer(id)
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
