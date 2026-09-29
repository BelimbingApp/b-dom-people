defmodule Bilimbi.People.Attendance.Web.RulesLive do
  @moduledoc "Operator-managed company clocking policy."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Attendance
  @capability "people.attendance.rules.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Attendance rules")
     |> assign(:active_nav, "people.attendance.rules")
     |> assign(:companies, companies)
     |> select_company(nil)}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, select_company(socket, id)}

  def handle_event("save", params, socket) do
    case socket.assigns.company do
      nil ->
        {:noreply, socket}

      company ->
        case Attendance.put_rules(
               socket.assigns.current_scope.scope,
               company.id,
               Map.get(params, "timezone", ""),
               Map.get(params, "enabled") == "true",
               parse_hours(Map.get(params, "max_shift_hours"))
             ) do
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
               "Enter a valid time zone and a shift length of 1 to 24 hours."
             )}
        end
    end
  end

  defp parse_hours(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {hours, ""} -> hours
      _ -> nil
    end
  end

  defp parse_hours(_), do: nil

  defp select_company(socket, id) do
    company =
      Enum.find(socket.assigns.companies, fn value ->
        id == Integer.to_string(value.id)
      end) || List.first(socket.assigns.companies)

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
        <.empty_state :if={@company == nil} id="attendance-rules-empty"
          title="No active company is available for attendance rules." />
        <form :if={@company} phx-change="select_company" id="attendance-company-form">
          <label for="attendance-company">Company</label>
          <select id="attendance-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <form :if={@rules} id="attendance-rules-form" phx-submit="save" class="mt-5 space-y-4">
          <label for="attendance-timezone">Attendance time zone</label>
          <input id="attendance-timezone" name="timezone" value={@rules.timezone}
            class="rounded-md border border-line bg-surface px-3 py-2" />
          <label class="flex gap-2"><input type="checkbox" name="enabled" value="true"
            checked={@rules.self_clock_enabled} />Allow employee clocking</label>
          <label for="attendance-max-shift">Maximum shift length (hours)</label>
          <input id="attendance-max-shift" name="max_shift_hours" type="number" min="1" max="24"
            value={@rules.max_shift_hours}
            class="rounded-md border border-line bg-surface px-3 py-2" />
          <.button type="submit" variant="primary">Save rules</.button>
        </form>
      </.page>
    </Layouts.app>
    """
  end
end
