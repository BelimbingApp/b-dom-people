defmodule Bilimbi.People.Attendance.Web.RulesLive do
  @moduledoc "Operator-managed company clocking policy."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents
  @capability "people.attendance.rules.manage"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Attendance rules")
     |> assign(:active_nav, "people.attendance.rules")
     |> assign(
       :companies,
       AttendanceComponents.companies(socket.assigns.current_scope.actor, @capability)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, select_company(socket, params["company_id"])}

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/attendance/rules?company_id=#{id}")}

  def handle_event("save", params, socket) do
    case socket.assigns.company do
      nil ->
        {:noreply, socket}

      company ->
        case Attendance.put_rules(socket.assigns.current_scope.scope, company.id, %{
               timezone: Map.get(params, "timezone", ""),
               self_clock_enabled: Map.get(params, "enabled") == "true",
               max_shift_hours: parse_integer(Map.get(params, "max_shift_hours")),
               location_required: Map.get(params, "location_required") == "true",
               adjustment_window_days: parse_integer(Map.get(params, "adjustment_window_days"))
             }) do
          {:ok, rules} ->
            {:noreply,
             socket
             |> assign(:rules, rules)
             |> put_flash(:success, "Attendance rules saved.")}

          _ ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Enter a valid time zone, a shift length of 1 to 24 hours, and an adjustment window of 1 to 366 days."
             )}
        end
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp select_company(socket, id) do
    company = AttendanceComponents.pick(socket.assigns.companies, id)

    rules =
      if company do
        case Attendance.rules(socket.assigns.current_scope.scope, company.id) do
          {:ok, value} -> value
          _ -> nil
        end
      end

    socket |> assign(:company, company) |> assign(:rules, rules)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-rules-page" variant={:form}>
        <.header>Attendance rules</.header>
        <AttendanceComponents.rules_tabs current={:rules} company={@company} />
        <.empty_state :if={@company == nil} id="attendance-rules-empty" class="mt-5"
          title="No active company is available for attendance rules." />
        <div :if={@company} class="mt-5">
          <AttendanceComponents.company_select id="attendance-company-form" companies={@companies} company={@company} />
        </div>
        <.empty_state :if={@company && @rules == nil} id="attendance-rules-unavailable" class="mt-5"
          title="Attendance rules are unavailable for this company."
          reason="The company's workforce is not current." />
        <form :if={@rules} id="attendance-rules-form" phx-submit="save" class="mt-5 space-y-4">
          <div>
            <label for="attendance-timezone" class="block text-sm font-medium text-ink-strong">Attendance time zone</label>
            <input id="attendance-timezone" name="timezone" value={@rules.timezone}
              class="mt-1 w-full rounded-md border border-line bg-surface px-3 py-2" />
          </div>
          <label class="flex gap-2"><input type="checkbox" name="enabled" value="true"
            checked={@rules.self_clock_enabled} />Allow employee clocking</label>
          <div>
            <label for="attendance-max-shift" class="block text-sm font-medium text-ink-strong">Maximum shift length (hours)</label>
            <input id="attendance-max-shift" name="max_shift_hours" type="number" min="1" max="24"
              value={@rules.max_shift_hours}
              class="mt-1 rounded-md border border-line bg-surface px-3 py-2" />
          </div>
          <label class="flex gap-2"><input type="checkbox" name="location_required" value="true"
            checked={@rules.location_required} />Require an active clocking location for clock events</label>
          <div>
            <label for="attendance-adjustment-window" class="block text-sm font-medium text-ink-strong">
              Adjustment request window (days, counting today)
            </label>
            <input id="attendance-adjustment-window" name="adjustment_window_days" type="number" min="1" max="366"
              value={@rules.adjustment_window_days}
              class="mt-1 rounded-md border border-line bg-surface px-3 py-2" />
          </div>
          <.button type="submit" variant="primary">Save rules</.button>
        </form>
      </.page>
    </Layouts.app>
    """
  end
end
