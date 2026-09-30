defmodule Bilimbi.People.Attendance.Web.MyLive do
  @moduledoc "Self attendance with account-to-employee resolution through Core User."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
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
     |> load()}
  end

  @impl true
  def handle_event("clock", params, socket) do
    current = socket.assigns.current_scope

    case Attendance.self_clock(
           current.scope,
           current.actor.company_id,
           current.actor,
           params["type"],
           socket.assigns.clock_key
         ) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:success, "Clock event recorded.")}

      {:error, reason} when reason in [:location_required, :outside_clocking_location] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Clock events here must come from an approved clocking location."
         )}

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Clocking is unavailable for this account.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Clock event could not be recorded.")}
    end
  end

  def handle_event("request_adjustment", %{"adjustment" => attrs}, socket) do
    current = socket.assigns.current_scope
    attrs = Map.put(attrs, "request_key", socket.assigns.request_key)

    case Attendance.submit_adjustment(
           current.scope,
           current.actor.company_id,
           current.actor,
           attrs
         ) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(:request_key, Ecto.UUID.generate())
         |> load()
         |> put_flash(:success, "Adjustment request submitted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("cancel_adjustment", %{"id" => id}, socket) do
    current = socket.assigns.current_scope

    with {id, ""} <- Integer.parse(id),
         {:ok, _} <-
           Attendance.cancel_adjustment(
             current.scope,
             current.actor.company_id,
             current.actor,
             id
           ) do
      {:noreply, socket |> load() |> put_flash(:success, "Adjustment request cancelled.")}
    else
      _ ->
        {:noreply,
         socket |> load() |> put_flash(:error, "The request can no longer be cancelled.")}
    end
  end

  def refusal(:invalid_time), do: "Enter a valid date and time."
  def refusal(:future_time), do: "The time cannot be in the future."
  def refusal(:outside_window), do: "That date is outside the adjustment request window."
  def refusal(:duplicate_request), do: "A request for this clock event already exists."
  def refusal(:unavailable), do: "Adjustment requests are unavailable for this account."
  def refusal(_), do: "Choose clock in or out, a time, and give a reason."

  defp load(socket) do
    current = socket.assigns.current_scope
    %{scope: scope, actor: actor} = current
    company_id = actor.company_id

    state =
      with {:ok, days} <- Attendance.self_days(scope, company_id, actor),
           {:ok, rules} <- Attendance.rules(scope, company_id),
           {:ok, today} <- Attendance.local_date(DateTime.utc_now(), rules.timezone),
           {:ok, shifts} <- Attendance.self_roster(scope, company_id, actor, today, @roster_days),
           {:ok, requests} <- Attendance.self_adjustments(scope, company_id, actor) do
        %{days: days, rules: rules, today: today, shifts: shifts, requests: requests}
      else
        _ -> :unavailable
      end

    socket
    |> assign(:clock_key, Ecto.UUID.generate())
    |> assign(:state, state)
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
            <div :if={@state.rules.self_clock_enabled and not @state.rules.location_required} class="flex gap-2 mt-5">
              <.button phx-click="clock" phx-value-type="in">
                Clock in
              </.button>
              <.button phx-click="clock" phx-value-type="out">
                Clock out
              </.button>
            </div>
            <.empty_state :if={!@state.rules.self_clock_enabled} id="my-attendance-clocking-off" class="mt-5"
              title="Self clocking is off." reason="An operator can enable it in Attendance rules." />
            <.empty_state :if={@state.rules.self_clock_enabled and @state.rules.location_required}
              id="my-attendance-location-required" class="mt-5"
              title="Clock in at an approved clocking location."
              reason="This company requires a verified location, which this page cannot report. Use a clocking point, or request an adjustment below." />
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
    """
  end

  defp badge_kind("approved"), do: :success
  defp badge_kind("rejected"), do: :danger
  defp badge_kind("pending"), do: :warning
  defp badge_kind(_), do: :neutral
end
