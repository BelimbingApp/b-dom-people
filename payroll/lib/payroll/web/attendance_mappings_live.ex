defmodule Bilimbi.People.Payroll.Web.AttendanceMappingsLive do
  @moduledoc "Company-scoped mapping from Attendance rules to payroll item codes."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Payroll

  @capability "people.payroll.attendance-mappings.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Attendance pay-item mappings")
     |> assign(:active_nav, nil)
     |> assign(:companies, companies)
     |> assign(:can_manage?, companies != [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = pick(socket.assigns.companies, params["company_id"])

    mappings =
      if company do
        case Payroll.attendance_allowances(scope(socket), company.id) do
          {:ok, values} -> values
          _ -> nil
        end
      end

    {:noreply, socket |> assign(:company, company) |> assign(:mappings, mappings)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("select_company", %{"company_id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/people/payroll/attendance-mappings?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("map", %{"rule_code" => rule_code, "pay_item_code" => pay_item_code}, socket) do
    case Payroll.put_attendance_allowance_mapping(
           scope(socket),
           socket.assigns.company.id,
           rule_code,
           pay_item_code
         ) do
      {:ok, _mapping} ->
        {:noreply, socket |> reload() |> put_flash(:success, "Attendance allowance mapped.")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Enter a valid pay item code for an available allowance rule.")}
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp pick(companies, id),
    do: Enum.find(companies, &(to_string(&1.id) == to_string(id))) || List.first(companies)

  defp reload(socket),
    do:
      handle_params(%{"company_id" => to_string(socket.assigns.company.id)}, nil, socket)
      |> elem(1)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payroll-attendance-mappings-page" variant={:list}>
        <.header>Attendance pay-item mappings</.header>
        <p class="mb-4 text-sm text-ink-muted">Map each current Attendance allowance rule to a payroll item code for this company.</p>
        <form :if={@companies != []} id="payroll-mapping-company-form" phx-change="select_company" class="mb-4">
          <label for="payroll-mapping-company" class="block text-sm font-medium text-ink-strong">Company</label>
          <select id="payroll-mapping-company" name="company_id" class="mt-1 rounded-md border border-line bg-surface px-3 py-1.5 text-sm">
            <option :for={company <- @companies} value={company.id} selected={@company && company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company == nil} id="payroll-mappings-no-company" title="No active company is available for pay-item mappings." />
        <.empty_state :if={@company && @mappings == nil} id="payroll-mappings-unavailable"
          title="Attendance allowance sources are unavailable for this company."
          reason="The company's workforce is not current." />
        <div :if={@mappings == []} class="rounded-xl border border-line bg-surface p-4 text-sm text-ink-muted">No allowance rules are effective today.</div>
        <div :if={@mappings not in [nil, []]} class="overflow-x-auto rounded-xl border border-line bg-surface">
          <table class="w-full text-sm">
            <thead class="bg-surface-sunken text-left text-xs font-semibold text-ink-subtle"><tr><th class="px-2 py-1.5">Attendance rule</th><th class="px-2 py-1.5">Value</th><th class="px-2 py-1.5">Pay item code</th><th class="px-2 py-1.5">Action</th></tr></thead>
            <tbody>
              <tr :for={source <- @mappings} id={"payroll-attendance-rule-#{source.id}"} class="border-t border-line">
                <td class="px-2 py-1"><span class="font-medium">{source.name}</span><span class="ml-2 text-ink-muted tabular-nums">{source.code}</span></td>
                <td class="px-2 py-1 tabular-nums">{source.value} {source.currency} / {source.unit}</td>
                <td class="px-2 py-1 tabular-nums">{source.pay_item_code || "Not mapped"}</td>
                <td class="px-2 py-1">
                  <form phx-submit="map" class="flex min-w-56 gap-2">
                    <input type="hidden" name="rule_code" value={source.code} />
                    <input name="pay_item_code" value={source.pay_item_code} required maxlength="40" aria-label={"Pay item code for #{source.name}"} class="min-w-0 flex-1 rounded-md border border-line bg-surface px-2 py-1.5" />
                    <.button type="submit" variant="primary">Save</.button>
                  </form>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
