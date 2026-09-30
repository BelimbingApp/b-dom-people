defmodule Bilimbi.People.Attendance.Web.LocationsLive do
  @moduledoc "Operator-managed clocking locations for one company."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents
  @capability "people.attendance.rules.manage"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Clocking locations")
     |> assign(:active_nav, "people.attendance.rules")
     |> assign(
       :companies,
       AttendanceComponents.companies(socket.assigns.current_scope.actor, @capability)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = AttendanceComponents.pick(socket.assigns.companies, params["company_id"])
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/people/attendance/rules/locations?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket), do: {:noreply, socket}

  def handle_event("create", %{"location" => attrs}, socket) do
    case Attendance.create_clocking_location(scope(socket), socket.assigns.company.id, attrs) do
      {:ok, _location} ->
        {:noreply, socket |> load() |> put_flash(:success, "Clocking location added.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          if Keyword.has_key?(changeset.errors, :company_id),
            do: "That code is already used by another clocking location.",
            else:
              "Enter a code, a name, a latitude from -90 to 90, a longitude from -180 to 180, and a radius from 1 to 100000 meters."

        {:noreply, put_flash(socket, :error, message)}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Clocking locations are unavailable for this company.")}
    end
  end

  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, _} <-
           Attendance.set_clocking_location_status(
             scope(socket),
             socket.assigns.company.id,
             id,
             status
           ) do
      {:noreply, socket |> load() |> put_flash(:success, "Clocking location updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Clocking location could not be updated.")}
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp load(%{assigns: %{company: nil}} = socket),
    do: socket |> assign(:locations, nil) |> assign(:required?, false)

  defp load(socket) do
    company_id = socket.assigns.company.id

    case {Attendance.list_clocking_locations(scope(socket), company_id),
          Attendance.rules(scope(socket), company_id)} do
      {{:ok, locations}, {:ok, rules}} ->
        socket |> assign(:locations, locations) |> assign(:required?, rules.location_required)

      _ ->
        socket |> assign(:locations, nil) |> assign(:required?, false)
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, AttendanceComponents.input_class())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-locations-page" variant={:form}>
        <.header>
          Attendance rules
          <:subtitle>Places where clock events count as on site.</:subtitle>
        </.header>
        <AttendanceComponents.rules_tabs current={:locations} company={@company} actor={@current_scope.actor} />
        <.empty_state :if={@company == nil} id="attendance-locations-no-company" class="mt-5"
          title="No active company is available for clocking locations." />
        <div :if={@company} class="mt-5 space-y-5">
          <AttendanceComponents.company_select id="attendance-locations-company" companies={@companies} company={@company} />
          <.empty_state :if={@locations == nil} id="attendance-locations-unavailable"
            title="Clocking locations are unavailable for this company."
            reason="The company's workforce is not current." />
          <.card :if={@locations} inner_class="p-5 sm:p-6" role="region" aria-labelledby="attendance-locations-heading">
            <.section_heading id="attendance-locations-heading" title="Clocking locations" />
            <p class="mt-1 text-xs text-ink-muted">
              {if @required?,
                do: "This company requires clock events to carry coordinates inside an active location.",
                else: "Locations are recorded on clock events; the company does not require them."}
            </p>
            <p :if={@locations == []} id="attendance-locations-empty" class="mt-2 text-sm text-ink-muted">
              No clocking locations have been added for this company.
            </p>
            <ul :if={@locations != []} class="mt-3 divide-y divide-line text-sm">
              <li :for={location <- @locations} id={"clocking-location-#{location.id}"} class="flex flex-wrap items-center gap-3 py-1.5">
                <span class="font-medium">{location.name}</span>
                <span class="text-ink-muted">{location.code}</span>
                <span class="text-ink-muted">{location.latitude}, {location.longitude} · {location.radius_meters} m</span>
                <.badge kind={if location.status == "active", do: :success, else: :neutral}>{location.status}</.badge>
                <button type="button" phx-click="set_status" phx-value-id={location.id}
                  phx-value-status={if location.status == "active", do: "retired", else: "active"}
                  class="text-link hover:underline">
                  {if location.status == "active", do: "Retire", else: "Reactivate"}
                </button>
              </li>
            </ul>
            <form id="attendance-location-form" phx-submit="create" class="mt-4 grid gap-2 sm:grid-cols-2">
              <input name="location[code]" aria-label="Location code" placeholder="Code" required maxlength="40" class={@input} />
              <input name="location[name]" aria-label="Location name" placeholder="Name" required maxlength="120" class={@input} />
              <input name="location[latitude]" aria-label="Latitude" placeholder="Latitude" required inputmode="decimal" class={@input} />
              <input name="location[longitude]" aria-label="Longitude" placeholder="Longitude" required inputmode="decimal" class={@input} />
              <input name="location[radius_meters]" type="number" min="1" max="100000" aria-label="Radius in meters" placeholder="Radius (m)" required class={@input} />
              <div><.button type="submit">Add clocking location</.button></div>
            </form>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
