defmodule Bilimbi.People.Attendance.Web.MyLive do
  @moduledoc "Self attendance with account-to-employee resolution through Core User."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My attendance")
     |> assign(:active_nav, "people.attendance.my")
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

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Clocking is unavailable for this account.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Clock event could not be recorded.")}
    end
  end

  defp load(socket) do
    current = socket.assigns.current_scope

    socket
    |> assign(:clock_key, Ecto.UUID.generate())
    |> assign(
      :state,
      with {:ok, days} <-
             Attendance.self_days(current.scope, current.actor.company_id, current.actor),
           {:ok, rules} <- Attendance.rules(current.scope, current.actor.company_id) do
        {:ok, days, rules.self_clock_enabled}
      else
        _ -> :unavailable
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="my-attendance-page">
        <.header>My attendance</.header>
        <.empty_state :if={@state == :unavailable} id="my-attendance-unavailable"
          title="Attendance is unavailable for this account."
          reason="Ask an operator to link your account to an active employee in this company." />
        <div :if={match?({:ok, _, _}, @state)}>
          <% {:ok, days, enabled} = @state %>
          <.empty_state :if={days == []} id="my-attendance-empty"
            title="No clock events yet." reason="Your recorded days will appear here." />
          <div :if={enabled} class="flex gap-2 mt-5">
            <.button phx-click="clock" phx-value-type="in">
              Clock in
            </.button>
            <.button phx-click="clock" phx-value-type="out">
              Clock out
            </.button>
          </div>
          <.empty_state :if={!enabled} id="my-attendance-clocking-off"
            title="Self clocking is off." reason="An operator can enable it in Attendance rules." />
          <ul class="mt-5 space-y-2">
            <li :for={day <- days} class="rounded-lg border border-line bg-surface p-3">
              <strong>{day.on_date}</strong> · {String.replace(day.status, "_", " ")} ·
              {day.worked_minutes} minutes
            </li>
          </ul>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
