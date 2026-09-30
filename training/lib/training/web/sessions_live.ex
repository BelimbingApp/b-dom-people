defmodule Bilimbi.People.Training.Web.SessionsLive do
  @moduledoc "Company training events and session calendar."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Base.DateTime, as: Clock
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.Web.Support
  @write_events ~w(open_event open_session create_event create_session)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sessions & calendar",
       active_nav: "people.development.sessions",
       companies:
         Support.companies(socket.assigns.current_scope, "people.training.sessions.view"),
       modal: nil,
       form: to_form(%{}, as: :entry)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.company(socket.assigns.companies, params)

    date =
      case Date.from_iso8601(params["date"] || "") do
        {:ok, value} -> Date.beginning_of_month(value)
        _ -> Date.beginning_of_month(Date.utc_today())
      end

    {:noreply,
     socket
     |> assign(
       company: company,
       params: params,
       date: date,
       calendar?: params["view"] == "calendar",
       modal: nil
     )
     |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's sessions.")}

  def handle_event("filter", %{"filters" => attrs}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         "/people/training/sessions?" <>
           URI.encode_query(
             Map.merge(socket.assigns.params, attrs)
             |> Map.take(~w(company_id date view perPage event_page session_page))
           )
     )}
  end

  def handle_event("event_page", %{"page" => page}, socket),
    do: change_page(socket, "event_page", page)

  def handle_event("session_page", %{"page" => page}, socket),
    do: change_page(socket, "session_page", page)

  def handle_event("open_event", _, socket),
    do:
      {:noreply, socket |> clear_flash() |> assign(modal: :event, form: to_form(%{}, as: :entry))}

  def handle_event("open_session", _, socket),
    do:
      {:noreply,
       socket
       |> clear_flash()
       |> assign(
         modal: :session,
         form: to_form(%{"time_zone" => socket.assigns.zone}, as: :entry)
       )}

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("create_event", %{"entry" => attrs}, socket),
    do: write(socket, attrs, &Training.create_event/3, "Event added.")

  def handle_event("create_session", %{"entry" => attrs}, socket),
    do: write(socket, attrs, &Training.create_session/3, "Session added.")

  defp change_page(socket, key, page) do
    {:noreply,
     push_patch(socket,
       to:
         "/people/training/sessions?" <>
           URI.encode_query(Map.put(socket.assigns.params, key, page))
     )}
  end

  defp write(socket, attrs, operation, message) do
    case operation.(socket.assigns.current_scope.scope, socket.assigns.company.id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> clear_flash() |> assign(modal: nil) |> put_flash(:success, message) |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(form: to_form(attrs, as: :entry))
         |> put_flash(:error, Support.message(reason))}
    end
  end

  defp load(socket) do
    %{company: company, date: date, current_scope: %{scope: scope}} = socket.assigns

    zone =
      if company,
        do: Clock.company_timezone(SettingsScope.company(company.id, Scope.tenant_id(scope))),
        else: "UTC"

    until = Date.add(Date.end_of_month(date), 1)

    can_manage? =
      company != nil and Training.allowed?(scope, company.id, "people.training.sessions.manage")

    result =
      if company do
        with {:ok, from} <- Training.local_instant("#{date}T00:00:00", zone),
             {:ok, until} <- Training.local_instant("#{until}T00:00:00", zone),
             {:ok, sessions} <- Training.calendar(scope, company.id, from, until),
             {:ok, events} <- Training.list_events(scope, company.id) do
          {:ok, sessions, events}
        end
      else
        {:error, :unauthorized}
      end

    {sessions, events, error} =
      case result do
        {:ok, sessions, events} -> {sessions, events, nil}
        {:error, reason} -> {[], [], Support.message(reason)}
      end

    courses =
      if can_manage? do
        case Training.event_courses(scope, company.id) do
          {:ok, values} -> values
          _ -> []
        end
      else
        []
      end

    days = Enum.to_list(Date.range(date, Date.end_of_month(date)))

    by_day =
      Map.new(days, fn day ->
        {day,
         Enum.filter(sessions, fn session ->
           {:ok, start_in_zone} = Clock.shift(session.starts_at, zone)
           start = DateTime.to_date(start_in_zone)
           {:ok, finish_in_zone} = Clock.shift(DateTime.add(session.ends_at, -1), zone)
           finish = DateTime.to_date(finish_in_zone)
           Date.compare(day, start) != :lt and Date.compare(day, finish) != :gt
         end)}
      end)

    assign(socket,
      sessions: sessions,
      session_page: Support.page(sessions, socket.assigns.params, "session_page"),
      event_page: Support.page(events, socket.assigns.params, "event_page"),
      events: events,
      courses: courses,
      days: days,
      by_day: by_day,
      error: error,
      can_manage?: can_manage? and error == nil,
      zone: zone,
      display: %Bilimbi.Base.DateTime.Display{
        mode: :company,
        timezone: zone,
        tz_db: Clock.time_zone_database()
      },
      filters:
        to_form(
          %{
            "company_id" => if(company, do: to_string(company.id), else: ""),
            "perPage" => socket.assigns.params["perPage"] || "25",
            "date" => Date.to_iso8601(date),
            "view" => if(socket.assigns.calendar?, do: "calendar", else: "list")
          },
          as: :filters
        )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page class="space-y-4">
        <.header>
          Sessions &amp; calendar
          <:actions :if={@can_manage?}>
            <div class="flex gap-3">
              <button :if={@courses != []} class="text-link" phx-click="open_event">Add event</button>
              <.button :if={@events != []} phx-click="open_session">Add session</.button>
            </div>
          </:actions>
        </.header>
        <.filter_toolbar id="session-filters" form={@filters} event="filter">
          <:control type={:select} field={@filters[:company_id]} id="session-company" label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
          <:control type={:date} field={@filters[:date]} id="session-month" label="Month containing date" />
          <:control type={:select} field={@filters[:view]} id="session-view" label="View" options={[{"List", "list"}, {"Calendar", "calendar"}]} />
        </.filter_toolbar>
        <p class="text-sm text-ink-muted">Calendar time zone: {@zone}</p>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <p :if={not @can_manage? and is_nil(@error)} class="text-sm text-ink-muted">Read-only. Ask an operator with session management access to schedule training.</p>
        <.empty_state :if={@can_manage? and @courses == []} title="No active courses" reason="Add an active course in Courses before creating an event." />
        <.empty_state :if={is_nil(@error) and @events == []} title="No events yet" reason="An operator can add an event for an active course, then schedule its sessions." />
        <section :if={@events != [] and is_nil(@error)}>
          <h2 class="font-semibold">Events</h2>
          <.table id="training-events" rows={@event_page.entries}>
            <:col :let={event} label="Event">{event.name}</:col>
            <:col :let={event} label="Course">{event.course_name}</:col>
            <:col :let={event} label="Capacity">{event.capacity}</:col>
          </.table>
          <.pagination id="event-pagination" page={@event_page} filters_form={@filters} filters_event="filter" page_event="event_page" />
        </section>
        <.empty_state :if={is_nil(@error) and @sessions == []} title="No sessions this month" reason="Choose another month or ask an operator to schedule a session." />
        <.alert :if={length(@sessions) == 500} kind={:warning}>Showing the first 500 sessions in this month. An operator can review further sessions through a narrower calendar interval.</.alert>
        <.table :if={not @calendar? and @sessions != []} id="training-sessions" rows={@session_page.entries} row_id={&"session-#{&1.id}"}>
          <:col :let={session} label="Session">{session.name}</:col>
          <:col :let={session} label="Event">{Enum.find_value(@events, &if(&1.id == session.event_id, do: &1.name))}</:col>
          <:col :let={session} label="Start"><.datetime id={"session-start-#{session.id}"} value={session.starts_at} /></:col>
          <:col :let={session} label="End"><.datetime id={"session-end-#{session.id}"} value={session.ends_at} /></:col>
          <:col :let={session} label="Delivery time zone">{session.time_zone}</:col>
          <:col :let={session} label="Capacity">{session.capacity}</:col>
        </.table>
        <.pagination :if={not @calendar? and @sessions != []} id="session-pagination" page={@session_page} filters_form={@filters} filters_event="filter" page_event="session_page" />
        <div :if={@calendar? and is_nil(@error)} id="training-calendar" class="grid grid-cols-1 gap-2 sm:grid-cols-3 lg:grid-cols-7">
          <section :for={day <- @days} class="min-w-0 rounded border border-line p-2">
            <h2 class="text-sm font-semibold">{Calendar.strftime(day, "%a %d")}</h2>
            <div :for={session <- @by_day[day]} class="mt-2 text-sm">
              <p>{session.name}</p><.datetime id={"calendar-#{day}-#{session.id}"} value={session.starts_at} format={:time} display={@display} />
              <p class="text-ink-muted">Capacity {session.capacity}</p>
            </div>
          </section>
        </div>
        <.modal :if={@modal} id="session-modal" title={if @modal == :event, do: "Add event", else: "Add session"} on_cancel={JS.push("close_modal")} flash={@flash}>
          <.form for={@form} id="training-entry-form" phx-submit={if @modal == :event, do: "create_event", else: "create_session"} class="space-y-3">
            <.input :if={@modal == :event} field={@form[:course_id]} type="select" label="Course" options={Enum.map(@courses, &{&1.name, &1.id})} required />
            <.input :if={@modal == :session} field={@form[:event_id]} type="select" label="Event" options={Enum.map(@events, &{&1.name, &1.id})} required />
            <.input field={@form[:name]} label="Name" required maxlength="160" />
            <.input field={@form[:capacity]} type="number" label="Capacity" min="1" required />
            <.input :if={@modal == :session} field={@form[:time_zone]} label="IANA time zone" required />
            <.input :if={@modal == :session} field={@form[:starts_local]} type="datetime-local" label="Local start" required />
            <.input :if={@modal == :session} field={@form[:ends_local]} type="datetime-local" label="Local end" required />
            <div class="flex justify-end gap-3"><button type="button" phx-click="close_modal">Cancel</button><.button type="submit" phx-disable-with="Adding…">Add</.button></div>
          </.form>
        </.modal>
      </.page>
    </Layouts.app>
    """
  end
end
