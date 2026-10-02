defmodule Bilimbi.People.Training.Insights do
  @moduledoc """
  Bounded operational attendance KPIs and authorized course drills.
  Arbitrary date windows expose no evaluation scores: effectiveness remains the
  frozen, suppressed Evaluation summary. Attendance drills and arbitrary windows
  require the existing company record-view capability; aggregate-only readers
  choose one frozen Effectiveness reporting period, so overlapping windows cannot
  be differenced, and see suppressed cohorts and counts.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Training

  alias Bilimbi.People.Training.{
    ParticipationFact,
    Session,
    Event,
    Course,
    Passport,
    EffectivenessSummary
  }

  def summary(%Scope{} = scope, company, params) do
    with {:ok, _} <- Training.authorize(scope, company, "people.training.insights.view"),
         {:ok, first, last} <- range(scope, company, params),
         minimum when is_integer(minimum) and minimum >= 2 <-
           Settings.get(
             "people.training.evaluation.minimum_cohort",
             SettingScope.company(company, Scope.tenant_id(scope))
           ) do
      query = facts(scope, company, first, last)

      groups =
        from(r in subquery(query),
          group_by: [r.course_id, r.course],
          select: %{
            course_id: r.course_id,
            course: r.course,
            employees: count(r.employee_id, :distinct),
            confirmed: filter(count(), r.status == "confirmed"),
            absent: filter(count(), r.status == "absent")
          }
        )

      total = Repo.aggregate(subquery(groups), :count)
      size = Passport.page_size(params)
      page = Passport.page_number(params, total, size)

      entries =
        Repo.all(
          from(r in subquery(groups),
            order_by: [asc: r.course, asc: r.course_id],
            limit: ^size,
            offset: ^((page - 1) * size)
          )
        )

      entries =
        Enum.map(entries, fn r ->
          cond do
            r.employees < minimum ->
              %{r | employees: nil, confirmed: nil, absent: nil} |> Map.put(:suppressed, true)

            r.confirmed < minimum or r.absent < minimum ->
              %{r | confirmed: nil, absent: nil} |> Map.put(:suppressed, false)

            true ->
              Map.put(r, :suppressed, false)
          end
        end)

      {:ok,
       %{
         entries: entries,
         page: page,
         page_size: size,
         total_entries: total,
         total_pages: ceil(total / size)
       }}
    else
      nil -> {:error, :report_not_configured}
      n when is_integer(n) -> {:error, :report_not_configured}
      error -> error
    end
  end

  def drill(%Scope{} = scope, company, course_id, params) do
    with {:ok, _} <- Training.authorize(scope, company, "people.training.insights.view"),
         {:ok, _} <- Training.authorize(scope, company, "people.training.records.view"),
         {:ok, first, last} <- window(params),
         {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:integer, course_id) do
      query = from(r in subquery(facts(scope, company, first, last)), where: r.course_id == ^id)
      total = Repo.aggregate(query, :count)
      size = Passport.page_size(params)
      page = Passport.page_number(params, total, size)

      entries =
        Repo.all(
          from(r in query,
            order_by: [desc: r.ends_at, asc: r.employee_id, desc: r.fact_id],
            limit: ^size,
            offset: ^((page - 1) * size)
          )
        )

      {:ok,
       %{
         entries: entries,
         page: page,
         page_size: size,
         total_entries: total,
         total_pages: ceil(total / size)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def periods(%Scope{} = scope, company) do
    with {:ok, _} <- Training.authorize(scope, company, "people.training.insights.view") do
      {:ok,
       Repo.all(
         from(s in scoped(EffectivenessSummary, scope, company),
           order_by: [desc: s.period_start],
           select: %{period_start: s.period_start, period_end: s.period_end}
         )
       )}
    end
  end

  def window(%{"from" => first, "until" => last}) when is_binary(first) and is_binary(last) do
    with {:ok, first} <- Date.from_iso8601(first),
         {:ok, last} <- Date.from_iso8601(last),
         days = Date.diff(last, first),
         true <- days >= 0 and days < 366 do
      bounds(first, last)
    else
      _ -> {:error, :invalid_insight_range}
    end
  end

  def window(_), do: {:error, :invalid_insight_range}

  defp range(scope, company, params) do
    if Training.allowed?(scope, company, "people.training.records.view") do
      window(params)
    else
      with {:ok, periods} <- periods(scope, company),
           %{period_start: first, period_end: last} <-
             Enum.find(periods, &(Date.to_iso8601(&1.period_start) == params["period"])) do
        bounds(first, last)
      else
        nil -> {:error, :report_period_unavailable}
        error -> error
      end
    end
  end

  defp bounds(first, last),
    do:
      {:ok, DateTime.new!(first, ~T[00:00:00], "Etc/UTC"),
       DateTime.new!(Date.add(last, 1), ~T[00:00:00], "Etc/UTC")}

  defp facts(scope, company, first, last) do
    latest =
      from(f in scoped(ParticipationFact, scope, company),
        distinct: [f.session_id, f.employee_id],
        order_by: [asc: f.session_id, asc: f.employee_id, desc: f.revision]
      )

    from(f in subquery(latest),
      join: s in Session,
      on: s.id == f.session_id,
      join: e in Event,
      on: e.id == s.event_id,
      join: c in Course,
      on: c.id == e.course_id,
      where: s.ends_at >= ^first and s.ends_at < ^last,
      select: %{
        fact_id: f.id,
        session_id: s.id,
        session: s.name,
        employee_id: f.employee_id,
        ends_at: s.ends_at,
        course_id: c.id,
        course: c.name,
        status: f.status
      }
    )
  end

  defp scoped(schema, scope, company),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company)
end
