defmodule Bilimbi.People.Attendance.Rosters do
  @moduledoc false
  # Shift templates and the draft/publish roster. Employees see only the
  # published value; planning edits the working value until the next publish.
  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Attendance.{Access, RosterEntry, ShiftTemplate}
  alias Bilimbi.People.Workforce.Authorization

  @rules_capability "people.attendance.rules.manage"
  @roster_capability "people.attendance.roster.manage"
  @self_capability "people.attendance.self.view"

  # Keeps one roster read or publish transaction to about a month of rows.
  @max_days 31
  # Keeps the planner grid renderable; search narrows larger companies.
  @max_employees 200

  def list_shift_templates(%Scope{} = scope, company_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(t in Tenancy.scope_query(ShiftTemplate, scope),
           where: t.company_id == ^company_id,
           order_by: [asc: t.status, asc: t.code]
         )
       )}
    end
  end

  def create_shift_template(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @rules_capability),
         {:ok, _company} <- Access.current_company(scope, company_id) do
      %ShiftTemplate{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> ShiftTemplate.changeset(attrs)
      |> Repo.insert()
    end
  end

  def set_shift_template_status(%Scope{} = scope, company_id, template_id, status)
      when status in ~w(active retired) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @rules_capability),
         {:ok, _company} <- Access.current_company(scope, company_id),
         %ShiftTemplate{} = template <- get_template(scope, company_id, template_id) do
      template |> ShiftTemplate.status_changeset(status) |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def set_shift_template_status(%Scope{}, _, _, _), do: {:error, :invalid_status}

  @doc """
  Working roster for up to #{@max_days} days from `from`, for at most
  #{@max_employees} current employees matching the optional `:query`.
  """
  def roster(scope, company_id, from, days, options \\ [])

  def roster(%Scope{} = scope, company_id, %Date{} = from, days, options)
      when days in 1..@max_days do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @roster_capability),
         {:ok, _company} <- Access.current_company(scope, company_id),
         {:ok, employees} <- Access.current_employees(scope, company_id),
         {:ok, templates} <- list_shift_templates(scope, company_id) do
      to = Date.add(from, days - 1)

      matching =
        employees
        |> Enum.filter(&matches?(&1, options[:query]))
        |> Enum.sort_by(&{&1.display_name, &1.employee_number})

      shown =
        matching
        |> Enum.take(@max_employees)
        |> Enum.map(fn employee ->
          %{
            id: String.to_integer(employee.reference.stable_id),
            name: employee.display_name,
            number: employee.employee_number
          }
        end)

      ids = Enum.map(shown, & &1.id)

      entries =
        from(e in Tenancy.scope_query(RosterEntry, scope),
          where:
            e.company_id == ^company_id and e.employee_id in ^ids and e.on_date >= ^from and
              e.on_date <= ^to
        )
        |> Repo.all()
        |> Map.new(&{{&1.employee_id, &1.on_date}, entry_view(&1)})

      {:ok,
       %{
         dates: Enum.map(0..(days - 1), &Date.add(from, &1)),
         employees: shown,
         truncated?: length(matching) > @max_employees,
         templates: templates,
         entries: entries,
         pending:
           scope
           |> period_entries(company_id, from, to)
           |> RosterEntry.where_pending()
           |> exclude(:order_by)
           |> Repo.aggregate(:count)
       }}
    end
  end

  def roster(%Scope{}, _, _, _, _), do: {:error, :invalid_period}

  @doc """
  Sets a working roster value: `{:shift, template_id}`, `:rest`, or `:none` to
  clear. A never-published cleared entry is removed outright.
  """
  def plan_roster_entry(%Scope{} = scope, company_id, employee_id, %Date{} = on_date, value) do
    with {:ok, actor} <- Authorization.authorize(scope, company_id, @roster_capability),
         {:ok, {kind, template_id}} <- plan_value(value),
         {:ok, _employee} <- Access.current_employee(scope, company_id, employee_id),
         :ok <- active_template(scope, company_id, template_id) do
      Access.transact(fn ->
        case locked_entry(scope, company_id, employee_id, on_date) do
          nil when kind == "none" ->
            {:ok, nil}

          nil ->
            %RosterEntry{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              employee_id: employee_id,
              on_date: on_date,
              kind: kind,
              shift_template_id: template_id,
              updated_by_user_id: actor.id
            }
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.unique_constraint([:company_id, :employee_id, :on_date],
              name: :people_attendance_roster_entries_company_employee_date_unique
            )
            |> Repo.insert(mode: :savepoint)
            |> case do
              {:ok, entry} -> {:ok, entry_view(entry)}
              {:error, _changeset} -> {:error, :concurrent_update}
            end

          %RosterEntry{published_kind: nil} = entry when kind == "none" ->
            with {:ok, _} <- Repo.delete(entry), do: {:ok, nil}

          entry ->
            entry
            |> Ecto.Changeset.change(
              kind: kind,
              shift_template_id: template_id,
              updated_by_user_id: actor.id
            )
            |> Repo.update()
            |> view_result()
        end
      end)
    end
  end

  def plan_roster_entry(%Scope{}, _, _, _, _), do: {:error, :invalid_entry}

  @doc "Publishes every pending entry between the two dates and returns their count."
  def publish_roster(%Scope{} = scope, company_id, %Date{} = from, %Date{} = to) do
    with {:ok, actor} <- Authorization.authorize(scope, company_id, @roster_capability),
         :ok <- period(from, to),
         {:ok, _company} <- Access.current_company(scope, company_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Access.transact(fn ->
        pending =
          scope
          |> period_entries(company_id, from, to)
          |> RosterEntry.where_pending()
          |> lock("FOR UPDATE")
          |> Repo.all()

        Enum.each(pending, &publish_entry(&1, actor, now))

        with {:ok, _} <-
               Audit.record_action(scope, %{
                 company_id: company_id,
                 actor_type: Atom.to_string(actor.type),
                 actor_id: actor.id,
                 event: "people.attendance.roster_published",
                 payload: %{
                   "from" => Date.to_iso8601(from),
                   "to" => Date.to_iso8601(to),
                   "entries" => length(pending)
                 },
                 occurred_at: NaiveDateTime.utc_now()
               }),
             do: {:ok, length(pending)}
      end)
    end
  end

  defp period_entries(scope, company_id, from, to) do
    from(e in Tenancy.scope_query(RosterEntry, scope),
      where: e.company_id == ^company_id and e.on_date >= ^from and e.on_date <= ^to,
      order_by: [asc: e.id]
    )
  end

  @doc "The signed-in actor's own published roster for up to #{@max_days} days from `from`."
  def self_roster(%Scope{} = scope, company_id, %Date{} = from, days)
      when days in 1..@max_days do
    with {:ok, %{employee_id: employee_id}} <-
           Authorization.authorize_self(scope, company_id, @self_capability) do
      to = Date.add(from, days - 1)

      {:ok,
       Repo.all(
         from(e in Tenancy.scope_query(RosterEntry, scope),
           left_join: t in ShiftTemplate,
           on: t.id == e.published_shift_template_id and t.company_id == e.company_id,
           where:
             e.company_id == ^company_id and e.employee_id == ^employee_id and
               e.on_date >= ^from and e.on_date <= ^to and not is_nil(e.published_kind),
           order_by: [asc: e.on_date],
           select: %{
             on_date: e.on_date,
             kind: e.published_kind,
             shift_code: t.code,
             shift_name: t.name,
             start_minute: t.start_minute,
             end_minute: t.end_minute,
             break_minutes: t.break_minutes
           }
         )
       )}
    end
  end

  def self_roster(%Scope{}, _, _, _), do: {:error, :invalid_period}

  defp publish_entry(%RosterEntry{kind: "none"} = entry, _actor, _now), do: Repo.delete!(entry)

  defp publish_entry(entry, actor, now) do
    entry
    |> Ecto.Changeset.change(
      published_kind: entry.kind,
      published_shift_template_id: entry.shift_template_id,
      published_at: now,
      published_by_user_id: actor.id,
      revision: if(entry.published_kind, do: entry.revision + 1, else: entry.revision)
    )
    |> Repo.update!()
  end

  defp period(from, to) do
    days = Date.diff(to, from) + 1
    if days in 1..@max_days, do: :ok, else: {:error, :invalid_period}
  end

  defp plan_value({:shift, id}) when is_integer(id), do: {:ok, {"shift", id}}
  defp plan_value(:rest), do: {:ok, {"rest", nil}}
  defp plan_value(:none), do: {:ok, {"none", nil}}
  defp plan_value(_), do: {:error, :invalid_entry}

  defp active_template(_scope, _company_id, nil), do: :ok

  defp active_template(scope, company_id, id) do
    case get_template(scope, company_id, id) do
      %ShiftTemplate{status: "active"} -> :ok
      _ -> {:error, :shift_unavailable}
    end
  end

  defp get_template(scope, company_id, id) when is_integer(id) do
    Repo.one(
      from(t in Tenancy.scope_query(ShiftTemplate, scope),
        where: t.company_id == ^company_id and t.id == ^id
      )
    )
  end

  defp get_template(_, _, _), do: nil

  defp locked_entry(scope, company_id, employee_id, on_date) do
    Repo.one(
      from(e in Tenancy.scope_query(RosterEntry, scope),
        where:
          e.company_id == ^company_id and e.employee_id == ^employee_id and
            e.on_date == ^on_date,
        lock: "FOR UPDATE"
      )
    )
  end

  defp view_result({:ok, entry}), do: {:ok, entry_view(entry)}
  defp view_result(error), do: error

  defp entry_view(entry) do
    %{
      kind: entry.kind,
      shift_template_id: entry.shift_template_id,
      published_kind: entry.published_kind,
      published_shift_template_id: entry.published_shift_template_id,
      pending?: RosterEntry.pending?(entry)
    }
  end

  defp matches?(_employee, query) when query in [nil, ""], do: true

  defp matches?(employee, query) do
    needle = String.downcase(query)

    String.contains?(String.downcase(employee.display_name), needle) or
      String.contains?(String.downcase(employee.employee_number), needle)
  end
end
