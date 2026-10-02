defmodule Bilimbi.People.Training.Passport do
  @moduledoc """
  Employee learning passports with current My/Team authority on every read.
  A passport uses the latest attendance revision; evidence keeps its original
  revision. Base Artifacts owns the PDF snapshot, attribution and retention.
  Stale workforce data is visible only for the login actor's own passport;
  team membership and document publication always require current workforce.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Authz, Artifacts, Repo, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.{Company, User}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Training.{
    Course,
    Event,
    Session,
    ParticipationFact,
    Evidence,
    DocumentOwner
  }

  def capability(:self), do: "people.training.passport.my.view"
  def capability(:team), do: "people.training.passport.team.view"

  def authorize(%Scope{} = scope, company, audience) when audience in [:self, :team] do
    actor = Scope.actor(scope)

    with true <- actor.type == :user and actor.company_id == company,
         true <- Authz.can(scope, capability(audience)).allowed,
         {:ok, %{status: "active"}} <- Company.get_company(scope, company) do
      {:ok, actor}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def employees(%Scope{} = scope, company, audience) do
    with {:ok, actor} <- authorize(scope, company, audience),
         {:ok, user} <- User.get_user(scope, company, actor.user_id),
         id when is_integer(id) <- user.employee_id,
         {:ok, own} <- Workforce.employee(scope, company, id) do
      case audience do
        :self ->
          case own do
            %ReadResult{value: value} when not is_nil(value) ->
              {:ok, %{employees: [value], workforce: own}}

            _ ->
              {:error, {:not_current, own.freshness}}
          end

        :team ->
          with {:ok, _} <- ReadResult.require_current(own),
               {:ok, read} <- Workforce.employees(scope, company),
               {:ok, employees} <- ReadResult.require_current(read) do
            team =
              Enum.filter(employees, fn e ->
                (e.reference.stable_id != to_string(id) and e.supervisor_reference) &&
                  e.supervisor_reference.stable_id == to_string(id)
              end)

            {:ok, %{employees: team, workforce: read}}
          end
      end
    else
      nil -> {:error, :employee_unavailable}
      error -> error
    end
  end

  def read(%Scope{} = scope, company, audience, employee_id, params \\ %{}) do
    with {:ok, directory} <- employees(scope, company, audience),
         employee when not is_nil(employee) <-
           Enum.find(directory.employees, &(&1.reference.stable_id == to_string(employee_id))) do
      query = from(r in subquery(rows_query(scope, company, employee_id)))
      size = page_size(params)
      total = Repo.aggregate(query, :count)
      page = page_number(params, total, size)

      rows =
        Repo.all(
          from(r in query,
            order_by: [desc: r.ends_at, desc: r.fact_id],
            limit: ^size,
            offset: ^((page - 1) * size)
          )
        )

      facts = Enum.map(rows, & &1.fact_id)

      documents =
        Repo.all(
          from(e in scoped(Evidence, scope, company),
            where: e.fact_id in ^facts,
            select: %{fact_id: e.fact_id, artifact_id: e.artifact_id}
          )
        )
        |> Enum.group_by(& &1.fact_id)

      rows = Enum.map(rows, &Map.put(&1, :evidence, Map.get(documents, &1.fact_id, [])))

      {:ok,
       %{
         employee: employee,
         workforce: directory.workforce,
         page: %{
           entries: rows,
           page: page,
           page_size: size,
           total_entries: total,
           total_pages: ceil(total / size)
         }
       }}
    else
      nil -> {:error, :outside_team}
      error -> error
    end
  end

  def can_read_fact?(%Scope{} = scope, company, fact_id) do
    with id when not is_nil(id) <- integer(fact_id),
         fact when not is_nil(fact) <-
           Repo.one(from(f in scoped(ParticipationFact, scope, company), where: f.id == ^id)) do
      Enum.any?([:self, :team], fn audience ->
        with {:ok, directory} <- employees(scope, company, audience) do
          Enum.any?(directory.employees, &(&1.reference.stable_id == to_string(fact.employee_id)))
        else
          _ -> false
        end
      end)
    else
      _ -> false
    end
  end

  def read_evidence(%Scope{} = scope, company, id),
    do: Artifacts.read(scope, company, Bilimbi.People.Training.DocumentOwner, id)

  def authorize_subject(%Scope{} = scope, company, subject, operation) do
    with [kind, id] when kind in ["self", "team"] <- String.split(subject, ":"),
         employee when not is_nil(employee) <- integer(id),
         audience = if(kind == "self", do: :self, else: :team),
         {:ok, passport} <- read(scope, company, audience, employee),
         true <-
           operation == :read or
             (Authz.can(scope, "people.training.passport.generate").allowed and
                passport.workforce.freshness == :current) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def generate(%Scope{} = scope, company, audience, employee_id) do
    subject = Atom.to_string(audience) <> ":" <> to_string(employee_id)

    with :ok <- authorize_subject(scope, company, subject, :create),
         {:ok, passport} <- read(scope, company, audience, employee_id),
         total = passport.page.total_entries,
         true <- total <= 1000 do
      # PDF size is a fixed implementation safety bound, never a partial passport.
      rows =
        Repo.all(
          from(r in subquery(rows_query(scope, company, employee_id)),
            order_by: [desc: r.ends_at, desc: r.fact_id],
            limit: 1001
          )
        )

      if length(rows) > 1000 do
        {:error, :passport_too_large}
      else
        Artifacts.generate_pdf(
          scope,
          company,
          DocumentOwner,
          %{subject: subject, kind: "passport"},
          %{
            title: "Training passport",
            blocks: [
              {:text, passport.employee.display_name},
              {:text, "Employee: " <> passport.employee.reference.stable_id},
              {:text, "Generated: " <> DateTime.to_iso8601(DateTime.utc_now())},
              {:text,
               "Latest attendance revisions at generation. Evidence remains attached to its original revision."},
              {:table, ["Course", "Session", "Completed (UTC)", "Attendance"],
               Enum.map(rows, fn r ->
                 [r.course, r.session, DateTime.to_iso8601(r.ends_at), r.status]
               end)}
            ]
          }
        )
      end
    else
      false -> {:error, :passport_too_large}
      error -> error
    end
  end

  def download(%Scope{} = scope, company, id),
    do: Artifacts.read(scope, company, DocumentOwner, id)

  defp rows_query(scope, company, employee_id) do
    latest =
      from(f in scoped(ParticipationFact, scope, company),
        where: f.employee_id == ^integer(employee_id),
        distinct: f.session_id,
        order_by: [asc: f.session_id, desc: f.revision]
      )

    from(f in subquery(latest),
      join: s in Session,
      on: s.id == f.session_id,
      join: e in Event,
      on: e.id == s.event_id,
      join: c in Course,
      on: c.id == e.course_id,
      select: %{
        fact_id: f.id,
        employee_id: f.employee_id,
        course: c.name,
        session: s.name,
        ends_at: s.ends_at,
        status: f.status,
        revision: f.revision
      }
    )
  end

  def workforce_warning(%ReadResult{freshness: :current}), do: nil

  def workforce_warning(%ReadResult{freshness: {:stale, at}}),
    do:
      "Workforce data is stale; last confirmed " <>
        DateTime.to_iso8601(at) <>
        ". Team access and document generation require current workforce data."

  def workforce_warning(%ReadResult{freshness: {:unavailable, _}}),
    do: "Workforce data is unavailable. Ask an operator to check the connection."

  defp scoped(schema, scope, company),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company)

  defp integer(id) when is_integer(id) and id > 0, do: id

  defp integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil

  def page_size(params),
    do:
      if(integer(params["perPage"]) in [25, 50, 100, 300],
        do: integer(params["perPage"]),
        else: 25
      )

  def page_number(params, total, size),
    do: min(integer(params["page"]) || 1, max(1, ceil(total / size)))
end
