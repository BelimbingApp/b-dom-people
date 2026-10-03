defmodule Bilimbi.People.Attendance.Web.MyLive do
  @moduledoc """
  Self attendance. The signed-in account's linked employee is resolved by the
  facade on every read and write, never cached here. An unlinked or relinked
  account shows the unavailable state on the next event.
  """
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Phoenix.LiveView.JS
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents

  # Published shifts shown ahead of today, kept short for a mobile page.
  @roster_days 14

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My attendance")
     |> assign(:active_nav, "people.attendance.my")
     |> assign(:request_key, Ecto.UUID.generate())
     |> load()
     |> attach_hook(:clock_authority, :handle_event, fn
       "clock", _params, socket -> {:cont, refresh_clock_authority(socket)}
       _event, _params, socket -> {:cont, socket}
     end)}
  end

  @impl true
  def handle_event("clock", _params, %{assigns: %{can_self_clock?: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "Self clocking is unavailable for this account.")}

  def handle_event("clock", params, socket) do
    current = socket.assigns.current_scope

    case Attendance.self_clock(
           current.scope,
           current.actor.company_id,
           params["type"],
           socket.assigns.clock_key,
           Map.take(params, ["latitude", "longitude"])
         ) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:success, "Clock event recorded.")}

      {:error, reason}
      when reason in [:location_required, :outside_clocking_location, :invalid_event] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           clock_refusal(reason)
         )}

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Clocking is unavailable for this account.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Clock event could not be recorded.")}
    end
  end

  def handle_event("clock_location_error", %{"reason" => reason}, socket) do
    message =
      case reason do
        "permission_denied" ->
          "Location permission was refused. Allow location access in your browser and try again, or request an adjustment below."

        _ ->
          "Your location is unavailable. Check location access and try again, or request an adjustment below."
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("request_adjustment", %{"adjustment" => attrs}, socket) do
    current = socket.assigns.current_scope
    attrs = Map.put(attrs, "request_key", socket.assigns.request_key)

    case Attendance.submit_adjustment(current.scope, current.actor.company_id, attrs) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(:request_key, Ecto.UUID.generate())
         |> load()
         |> put_flash(:success, "Adjustment request submitted.")}

      {:error, reason} when reason in [:not_linked, :unauthorized] ->
        {:noreply, socket |> load() |> put_flash(:error, refusal(reason))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("cancel_adjustment", %{"id" => id}, socket) do
    current = socket.assigns.current_scope

    with {id, ""} <- Integer.parse(id),
         {:ok, _} <- Attendance.cancel_adjustment(current.scope, current.actor.company_id, id) do
      {:noreply, socket |> load() |> put_flash(:success, "Adjustment request cancelled.")}
    else
      _ ->
        {:noreply,
         socket |> load() |> put_flash(:error, "The request can no longer be cancelled.")}
    end
  end

  defp clock_refusal(:outside_clocking_location),
    do:
      "You are outside this company's approved clocking locations. Move to an approved location and try again, or request an adjustment below."

  defp clock_refusal(_),
    do: "A valid location is required to clock here. Try again, or request an adjustment below."

  defp refresh_clock_authority(socket) do
    %{scope: scope, actor: actor} = socket.assigns.current_scope
    assign(socket, :can_self_clock?, Attendance.can_self_clock?(scope, actor.company_id))
  end

  def refusal(:invalid_time), do: "Enter a valid date and time."
  def refusal(:future_time), do: "The time cannot be in the future."
  def refusal(:outside_window), do: "That date is outside the adjustment request window."
  def refusal(:duplicate_request), do: "A request for this clock event already exists."
  def refusal(:unavailable), do: "Adjustment requests are unavailable for this account."

  def refusal(:not_linked),
    do: "Your account is no longer linked to a working employee in this company."

  def refusal(:unauthorized),
    do: "You no longer have permission to use attendance self-service here."

  def refusal(_), do: "Choose clock in or out, a time, and give a reason."

  defp load(socket) do
    current = socket.assigns.current_scope
    %{scope: scope, actor: actor} = current
    company_id = actor.company_id

    state =
      with {:ok, days} <- Attendance.self_days(scope, company_id),
           {:ok, rules} <- Attendance.rules(scope, company_id),
           {:ok, today} <- Attendance.local_date(DateTime.utc_now(), rules.timezone),
           {:ok, shifts} <- Attendance.self_roster(scope, company_id, today, @roster_days),
           {:ok, requests} <- Attendance.self_adjustments(scope, company_id) do
        %{days: days, rules: rules, today: today, shifts: shifts, requests: requests}
      else
        _ -> :unavailable
      end

    socket
    |> assign(:clock_key, Ecto.UUID.generate())
    |> assign(:state, state)
    |> refresh_clock_authority()
  end

  defp shift_label(%{kind: "rest"}), do: "Rest day"

  defp shift_label(shift) do
    "#{shift.shift_name} (#{shift.shift_code}) #{AttendanceComponents.shift_hours(shift)}"
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:input, AttendanceComponents.input_class())
      |> assign(:roster_days, @roster_days)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="my-attendance-page">
        <.header>My attendance</.header>
        <.empty_state :if={@state == :unavailable} id="my-attendance-unavailable"
          title="Attendance is unavailable for this account."
          reason="Ask an operator to link your account to an active employee in this company." />
        <div :if={@state != :unavailable} class="space-y-6">
          <section aria-labelledby="my-attendance-clock-heading">
            <h2 id="my-attendance-clock-heading" class="sr-only">Clocking</h2>
            <div :if={@state.rules.self_clock_enabled} id="my-attendance-clock"
              phx-hook=".ClockLocation" data-authorized={to_string(@can_self_clock?)} data-location-required={to_string(@state.rules.location_required)} class="mt-5">
              <p :if={@state.rules.location_required} id="my-attendance-location-required" class="text-sm text-ink-muted">
                This company requires your location inside an approved clocking location.
                Your browser will ask for location access when you clock. If it is unavailable, request an adjustment below.
              </p>
              <div class="mt-3 flex flex-wrap gap-2">
                <.button data-clock-type="in" disabled={!@can_self_clock?}
                  phx-click={JS.dispatch("attendance:clock", detail: %{type: "in"})}>
                  Clock in
                </.button>
                <.button data-clock-type="out" disabled={!@can_self_clock?}
                  phx-click={JS.dispatch("attendance:clock", detail: %{type: "out"})}>
                  Clock out
                </.button>
              </div>
              <p id="my-attendance-location-status" phx-update="ignore" role="status" aria-live="polite"
                class="mt-2 text-sm text-ink-muted"></p>
              <p :if={!@can_self_clock?} class="mt-2 text-sm text-ink-muted">
                Self clocking is unavailable for this account.
              </p>
            </div>
            <.empty_state :if={!@state.rules.self_clock_enabled} id="my-attendance-clocking-off" class="mt-5"
              title="Self clocking is off." reason="An operator can enable it in Attendance rules." />
          </section>

          <section aria-labelledby="my-attendance-shifts-heading">
            <.section_heading id="my-attendance-shifts-heading" title="Upcoming shifts" />
            <p :if={@state.shifts == []} id="my-attendance-shifts-empty" class="mt-2 text-sm text-ink-muted">
              No published shifts for the next {@roster_days} days.
            </p>
            <ul :if={@state.shifts != []} class="mt-2 divide-y divide-line text-sm">
              <li :for={shift <- @state.shifts} class="flex gap-3 py-1.5">
                <span class="w-28 shrink-0 font-medium">{Calendar.strftime(shift.on_date, "%a %d %b")}</span>
                <span>{shift_label(shift)}</span>
              </li>
            </ul>
          </section>

          <section aria-labelledby="my-attendance-days-heading">
            <.section_heading id="my-attendance-days-heading" title="Recent days" />
            <.empty_state :if={@state.days == []} id="my-attendance-empty" class="mt-2"
              title="No clock events yet." reason="Your recorded days will appear here." />
            <ul class="mt-2 space-y-2">
              <li :for={day <- @state.days} class="rounded-lg border border-line bg-surface p-3">
                <strong>{day.on_date}</strong> · {String.replace(day.status, "_", " ")} ·
                {day.worked_minutes} minutes
              </li>
            </ul>
          </section>

          <section aria-labelledby="my-attendance-adjust-heading">
            <.section_heading id="my-attendance-adjust-heading" title="Request an adjustment" />
            <p class="mt-1 text-xs text-ink-muted">
              For a missed clock event in the last {@state.rules.adjustment_window_days}
              {if @state.rules.adjustment_window_days == 1, do: "day", else: "days"}, in {@state.rules.timezone} time. An approver adds it once accepted.
            </p>
            <form id="my-attendance-adjustment-form" phx-submit="request_adjustment" class="mt-3 grid gap-2 sm:grid-cols-2">
              <select name="adjustment[event_type]" aria-label="Clock event" class={@input}>
                <option value="in">Clock in</option>
                <option value="out">Clock out</option>
              </select>
              <input name="adjustment[local_at]" type="datetime-local" aria-label="Time" required class={@input} />
              <input name="adjustment[reason]" aria-label="Reason" placeholder="Reason" required maxlength="500"
                class={["sm:col-span-2", @input]} />
              <div><.button type="submit">Submit request</.button></div>
            </form>
            <p :if={@state.requests == []} id="my-attendance-requests-empty" class="mt-3 text-sm text-ink-muted">
              You have no adjustment requests.
            </p>
            <ul :if={@state.requests != []} class="mt-3 divide-y divide-line text-sm">
              <li :for={request <- @state.requests} id={"my-adjustment-#{request.id}"} class="flex flex-wrap items-center gap-3 py-1.5">
                <span class="font-medium">{AttendanceComponents.clock_label(request.event_type)}</span>
                <span>{AttendanceComponents.local_time(request.proposed_at, request.timezone)}</span>
                <.badge kind={badge_kind(request.status)}>{request.status}</.badge>
                <span :if={request.decision_note} class="text-ink-muted">{request.decision_note}</span>
                <button :if={request.status == "pending"} type="button" phx-click="cancel_adjustment"
                  phx-value-id={request.id} class="text-link hover:underline">Cancel</button>
              </li>
            </ul>
          </section>
        </div>
      </.page>
    </Layouts.app>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ClockLocation">
      export default {
        mounted() {
          this.busy = false
          this.generation = 0
          this.connected = true
          this.onClock = event => {
            const type = event.detail.type
            if (this.busy || !this.connected || !["in", "out"].includes(type)) return
            const button = this.el.querySelector(`[data-clock-type="${type}"]`)
            if (!button || button.disabled) return
            this.busy = true
            const generation = ++this.generation
            this.setBusy(true)
            const current = () => this.connected && this.generation === generation
            const finish = () => {
              if (!current()) return
              this.busy = false
              this.setBusy(false)
              this.status("")
            }
            const failed = reason => {
              if (!current()) return
              this.pushEvent("clock_location_error", {reason}, finish)
            }
            const record = coordinates => {
              if (!current()) return
              this.status("Recording clock event…")
              this.pushEvent("clock", {type, ...coordinates}, finish)
            }
            if (this.el.dataset.locationRequired !== "true") {
              record({})
              return
            }
            this.status("Finding your location…")
            if (!window.isSecureContext || !navigator.geolocation) {
              failed("unavailable")
              return
            }
            try {
              navigator.geolocation.getCurrentPosition(position => {
              const {latitude, longitude} = position.coords || {}
              if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
                failed("unavailable")
                return
              }
              record({latitude, longitude})
            }, error => failed(error.code === 1 ? "permission_denied" : "unavailable"),
              {enableHighAccuracy: true, maximumAge: 0, timeout: 15000})
            } catch (_error) {
              failed("unavailable")
            }
          }
          this.el.addEventListener("attendance:clock", this.onClock)
        },
        status(message) {
          this.el.querySelector("[role=status]").textContent = message
        },
        setBusy(busy) {
          this.el.setAttribute("aria-busy", String(busy))
          this.el.querySelectorAll("[data-clock-type]").forEach(button => {
            button.disabled = busy || this.el.dataset.authorized !== "true"
          })
        },
        updated() {
          if (this.busy) this.setBusy(true)
        },
        disconnected() {
          this.connected = false
          this.generation++
          this.busy = false
          this.setBusy(false)
          this.status("Clocking is unavailable while reconnecting. Try again when connected, or request an adjustment.")
        },
        reconnected() {
          this.connected = true
          this.status("")
        },
        destroyed() {
          this.connected = false
          this.generation++
          this.el.removeEventListener("attendance:clock", this.onClock)
        }
      }
    </script>
    """
  end

  defp badge_kind("approved"), do: :success
  defp badge_kind("rejected"), do: :danger
  defp badge_kind("pending"), do: :warning
  defp badge_kind(_), do: :neutral
end
