defmodule Bilimbi.People.Payroll.Web.AttendanceMappingsLive do
  @moduledoc "Company-scoped, effective-dated mapping from Attendance rules to pay items."
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

    data =
      if company do
        case Payroll.attendance_allowances(scope(socket), company.id) do
          {:ok, values} -> values
          _ -> nil
        end
      end

    {:noreply, socket |> assign(:company, company) |> assign(:data, data)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("select_company", %{"company_id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/people/payroll/attendance-mappings?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("create", %{"mapping" => attrs}, socket) do
    case Payroll.create_attendance_allowance_mapping(
           scope(socket),
           socket.assigns.company.id,
           attrs
         ) do
      {:ok, _mapping} ->
        {:noreply, socket |> reload() |> put_flash(:success, "Attendance allowance mapped.")}

      {:error, :overlapping_version} ->
        {:noreply, put_flash(socket, :error, "This rule already has a pay item for those dates.")}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose an allowance rule and a pay item effective for the whole mapping period."
         )}
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp pick(companies, id),
    do: Enum.find(companies, &(to_string(&1.id) == to_string(id))) || List.first(companies)

  defp reload(socket),
    do:
      handle_params(%{"company_id" => to_string(socket.assigns.company.id)}, nil, socket)
      |> elem(1)

  defp current_items(data, code) do
    today = Date.utc_today()

    labels =
      for mapping <- data.mappings,
          mapping.attendance_rule_code == code,
          Date.compare(mapping.effective_from, today) != :gt,
          is_nil(mapping.effective_to) or Date.compare(mapping.effective_to, today) != :lt,
          do: item_label(data.items, mapping.item_id)

    if labels == [], do: "Not mapped", else: Enum.join(labels, ", ")
  end

  defp item_label(items, id) do
    case Enum.find(items, &(&1.id == id)) do
      nil -> "Item #{id}"
      item -> "#{item.name} · #{item.code} · #{item.currency}"
    end
  end

  defp item_option(item),
    do:
      {"#{item.name} · #{item.code} · #{item.currency} · #{item.effective_from} to #{item.effective_to || "open"}",
       item.id}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payroll-attendance-mappings-page" variant={:list}>
        <.header>Attendance pay-item mappings</.header>
        <p class="mb-4 text-sm text-ink-muted">
          Map each Attendance allowance rule code to a company pay item for an effective period. Versions are append-only.
        </p>
        <form
          :if={@companies != []}
          id="payroll-mapping-company-form"
          phx-change="select_company"
          class="mb-4"
        >
          <label for="payroll-mapping-company" class="block text-sm font-medium text-ink-strong">Company</label>
          <select
            id="payroll-mapping-company"
            name="company_id"
            class="mt-1 rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
          >
            <option
              :for={company <- @companies}
              value={company.id}
              selected={@company && company.id == @company.id}
            >
              {company.name}
            </option>
          </select>
        </form>
        <.empty_state
          :if={@company == nil}
          id="payroll-mappings-no-company"
          title="No active company is available for pay-item mappings."
        />
        <.empty_state
          :if={@company && @data == nil}
          id="payroll-mappings-unavailable"
          title="Attendance allowance sources are unavailable for this company."
          reason="The company's workforce is not current."
        />
        <div :if={@data} class="space-y-6">
          <div
            :if={@data.sources == []}
            class="rounded-xl border border-line bg-surface p-4 text-sm text-ink-muted"
          >
            No current or future allowance rules are configured.
          </div>
          <div
            :if={@data.sources != []}
            class="overflow-x-auto rounded-xl border border-line bg-surface"
          >
            <table class="w-full text-sm">
              <thead class="bg-surface-sunken text-left text-xs font-semibold text-ink-subtle">
                <tr>
                  <th class="px-2 py-1.5">Attendance rule</th><th class="px-2 py-1.5">Value</th><th class="px-2 py-1.5">
                    Effective
                  </th><th class="px-2 py-1.5">Pay items today</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={source <- @data.sources}
                  id={"payroll-attendance-rule-#{source.id}"}
                  class="border-t border-line"
                >
                  <td class="px-2 py-1">
                    <span class="font-medium">{source.name}</span><span class="ml-2 text-ink-muted tabular-nums">{source.code}</span>
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    {source.value} {source.currency} / {source.unit}
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    {source.effective_from} to {source.effective_until || "open"}
                  </td>
                  <td class="px-2 py-1">{current_items(@data, source.code)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p
            :if={@data.sources != [] and @data.items == []}
            id="payroll-mappings-no-items"
            class="text-sm text-ink-muted"
          >
            Add a pay item in Payroll setup before mapping allowance rules.
          </p>
          <section
            :if={@data.sources != [] and @data.items != []}
            class="rounded-xl border border-line bg-surface p-4"
          >
            <h2 class="font-semibold text-ink-strong">Add mapping version</h2>
            <form
              id="payroll-attendance-mapping-form"
              phx-submit="create"
              class="mt-4 grid gap-3 sm:grid-cols-2"
            >
              <label class="text-sm">
                Attendance rule
                <select
                  name="mapping[attendance_rule_code]"
                  required
                  class="mt-1 w-full rounded-md border border-line bg-surface px-3 py-1.5"
                >
                  <option :for={source <- Enum.uniq_by(@data.sources, & &1.code)} value={source.code}>
                    {source.name} · {source.code}
                  </option>
                </select>
              </label>
              <label class="text-sm">
                Pay item
                <select
                  name="mapping[item_id]"
                  required
                  class="mt-1 w-full rounded-md border border-line bg-surface px-3 py-1.5"
                >
                  <option :for={{label, id} <- Enum.map(@data.items, &item_option/1)} value={id}>
                    {label}
                  </option>
                </select>
              </label>
              <label class="text-sm">Effective from<input
                name="mapping[effective_from]"
                required
                type="date"
                class="mt-1 w-full rounded-md border border-line bg-surface px-3 py-1.5"
              /></label>
              <label class="text-sm">Effective to<input
                name="mapping[effective_to]"
                type="date"
                class="mt-1 w-full rounded-md border border-line bg-surface px-3 py-1.5"
              /></label>
              <div class="sm:col-span-2">
                <.button type="submit" variant="primary">Add mapping</.button>
              </div>
            </form>
          </section>
          <section :if={@data.mappings != []}>
            <h2 class="mb-2 font-semibold text-ink-strong">Mapping history</h2>
            <ul class="space-y-1 text-sm">
              <li :for={mapping <- @data.mappings} id={"payroll-attendance-mapping-#{mapping.id}"}>
                {mapping.attendance_rule_code} → {item_label(@data.items, mapping.item_id)} · {mapping.effective_from} to {mapping.effective_to ||
                  "open"}
              </li>
            </ul>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
