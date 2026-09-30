defmodule Bilimbi.People.Attendance.Web.RostersLive do
  @moduledoc """
  Weekly roster planning for one company. Cell changes are drafts; employees
  see them only after the planner publishes the week.
  """
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents
  @capability "people.attendance.roster.manage"
  @days 7

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Rosters")
     |> assign(:active_nav, "people.attendance.rosters")
     |> assign(
       :companies,
       AttendanceComponents.companies(socket.assigns.current_scope.actor, @capability)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = AttendanceComponents.pick(socket.assigns.companies, params["company_id"])

    {:noreply,
     socket
     |> assign(:company, company)
     |> assign(:query, String.trim(params["q"] || ""))
     |> assign(:from, parse_date(params["from"]))
     |> load()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/attendance/rosters?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{roster: nil}} = socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    from = parse_date(params["from"]) || socket.assigns.from
    {:noreply, push_patch(socket, to: roster_path(socket, from, String.trim(params["q"] || "")))}
  end

  def handle_event("plan", %{"employee_id" => employee_id, "on_date" => on_date} = params, socket) do
    with {employee_id, ""} <- Integer.parse(employee_id),
         {:ok, on_date} <- Date.from_iso8601(on_date),
         {:ok, value} <- plan_value(params["value"]),
         {:ok, _entry} <-
           Attendance.plan_roster_entry(
             scope(socket),
             socket.assigns.company.id,
             socket.assigns.current_scope.actor,
             employee_id,
             on_date,
             value
           ) do
      {:noreply, load(socket)}
    else
      {:error, :shift_unavailable} ->
        {:noreply, socket |> load() |> put_flash(:error, "That shift template is retired.")}

      _ ->
        {:noreply, socket |> load() |> put_flash(:error, "The roster entry could not be saved.")}
    end
  end

  def handle_event("publish", _params, socket) do
    from = socket.assigns.from

    case Attendance.publish_roster(
           scope(socket),
           socket.assigns.company.id,
           socket.assigns.current_scope.actor,
           from,
           Date.add(from, @days - 1)
         ) do
      {:ok, count} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(
           :success,
           "Published #{count} roster #{if count == 1, do: "change", else: "changes"}."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "The roster could not be published.")}
    end
  end

  defp plan_value(""), do: {:ok, :none}
  defp plan_value("rest"), do: {:ok, :rest}

  defp plan_value("shift:" <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, {:shift, id}}
      _ -> :error
    end
  end

  defp plan_value(_), do: :error

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp roster_path(socket, from, query) do
    ~p"/people/attendance/rosters?company_id=#{socket.assigns.company.id}&from=#{Date.to_iso8601(from)}&q=#{query}"
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp load(%{assigns: %{company: nil}} = socket), do: assign(socket, :roster, nil)

  defp load(socket) do
    company_id = socket.assigns.company.id

    with {:ok, rules} <- Attendance.rules(scope(socket), company_id),
         from = socket.assigns.from || today(rules.timezone),
         {:ok, roster} <-
           Attendance.roster(scope(socket), company_id, from, @days, query: socket.assigns.query) do
      socket |> assign(:from, from) |> assign(:roster, roster)
    else
      _ -> assign(socket, :roster, nil)
    end
  end

  defp today(timezone) do
    case Attendance.local_date(DateTime.utc_now(), timezone) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp cell_value(nil), do: ""
  defp cell_value(%{kind: "shift", shift_template_id: id}), do: "shift:#{id}"
  defp cell_value(%{kind: "rest"}), do: "rest"
  defp cell_value(_), do: ""

  defp options(templates, entry) do
    current = entry && entry.shift_template_id

    templates
    |> Enum.filter(&(&1.status == "active" or &1.id == current))
    |> Enum.map(fn template ->
      suffix = if template.status == "active", do: "", else: " (retired)"

      {"#{template.code} #{AttendanceComponents.shift_hours(template)}#{suffix}",
       "shift:#{template.id}"}
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, AttendanceComponents.input_class())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-rosters-page">
        <.header>
          Rosters
          <:subtitle>Plan a week of shifts and rest days, then publish it to employees.</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="attendance-rosters-no-company" class="mt-5"
          title="No active company is available for rosters." />
        <div :if={@company} class="mt-5 space-y-4">
          <div class="max-w-md">
            <AttendanceComponents.company_select id="attendance-rosters-company" companies={@companies} company={@company} />
          </div>
          <.empty_state :if={@roster == nil} id="attendance-rosters-unavailable"
            title="The roster is unavailable for this company."
            reason="The company's workforce is not current." />
          <div :if={@roster} class="space-y-4">
            <form id="attendance-roster-filter" phx-submit="filter" class="flex flex-wrap items-end gap-2">
              <label class="text-sm text-ink">Week from
                <input name="from" type="date" value={Date.to_iso8601(@from)} class={["ml-2", @input]} />
              </label>
              <input name="q" value={@query} aria-label="Search employees" placeholder="Name or number" class={@input} />
              <.button type="submit">Show</.button>
              <.link patch={roster_path(assigns_socket(assigns), Date.add(@from, -7), @query)} id="roster-previous-week" class="text-sm text-link hover:underline">
                Previous week
              </.link>
              <.link patch={roster_path(assigns_socket(assigns), Date.add(@from, 7), @query)} id="roster-next-week" class="text-sm text-link hover:underline">
                Next week
              </.link>
            </form>
            <div class="flex flex-wrap items-center gap-3">
              <p id="attendance-roster-pending" class="text-sm text-ink-muted">
                {if @roster.pending == 0,
                  do: "No unpublished changes this week for this company.",
                  else: "#{@roster.pending} unpublished #{if @roster.pending == 1, do: "change", else: "changes"} this week across the company. Publish week releases all of them, including employees outside this list."}
              </p>
              <.button :if={@roster.pending > 0} id="attendance-roster-publish" phx-click="publish" variant="primary">
                Publish week
              </.button>
            </div>
            <p :if={Enum.all?(@roster.templates, &(&1.status != "active"))} id="attendance-roster-no-shifts" class="text-sm text-ink-muted">
              No active shift templates yet; only rest days can be planned.
              <.link navigate={~p"/people/attendance/rules/shifts?company_id=#{@company.id}"} class="text-link hover:underline">Add shift templates</.link>
            </p>
            <.empty_state :if={@roster.employees == []} id="attendance-roster-empty"
              title={if @query == "", do: "No working employees in this company.", else: "No employees match this search."} />
            <p :if={@roster.truncated?} class="text-xs text-ink-muted">
              Showing the first employees only; search to narrow the list.
            </p>
            <div :if={@roster.employees != []} class="overflow-x-auto border border-line bg-surface" id="attendance-roster-grid">
              <table class="min-w-full text-left text-sm">
                <caption class="sr-only">Roster for the week</caption>
                <thead class="border-b border-line bg-surface-sunken">
                  <tr>
                    <th class="sticky left-0 bg-surface-sunken px-2 py-1.5 font-medium">Employee</th>
                    <th :for={date <- @roster.dates} class="px-2 py-1.5 font-medium whitespace-nowrap">
                      {Calendar.strftime(date, "%a %d %b")}
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-line">
                  <tr :for={employee <- @roster.employees} id={"roster-row-#{employee.id}"}>
                    <th class="sticky left-0 bg-surface px-2 py-1 font-normal whitespace-nowrap">
                      {employee.name} <span class="text-ink-muted">{employee.number}</span>
                    </th>
                    <td :for={date <- @roster.dates} class="px-1 py-1">
                      <% entry = Map.get(@roster.entries, {employee.id, date}) %>
                      <form id={"roster-cell-#{employee.id}-#{date}"} phx-change="plan">
                        <input type="hidden" name="employee_id" value={employee.id} />
                        <input type="hidden" name="on_date" value={Date.to_iso8601(date)} />
                        <select name="value" aria-label={"#{employee.name} on #{date}"}
                          class={["w-44", @input, entry && entry.pending? && "border-warning"]}>
                          <option value="" selected={cell_value(entry) == ""}>Not rostered</option>
                          <option value="rest" selected={cell_value(entry) == "rest"}>Rest day</option>
                          <option :for={{label, value} <- options(@roster.templates, entry)} value={value}
                            selected={cell_value(entry) == value}>{label}</option>
                        </select>
                        <span :if={entry && entry.pending?} class="block text-xs text-ink-muted">Draft</span>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp assigns_socket(assigns), do: %{assigns: assigns}
end
