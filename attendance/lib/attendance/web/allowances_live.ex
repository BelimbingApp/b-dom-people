defmodule Bilimbi.People.Attendance.Web.AllowancesLive do
  @moduledoc "Operator-managed effective-dated allowance rules."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents

  @capability "people.attendance.allowances.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Allowance rules")
     |> assign(:active_nav, "people.attendance.rules")
     |> assign(:companies, companies)
     |> assign(:can_manage?, companies != [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = AttendanceComponents.pick(socket.assigns.companies, params["company_id"])

    rules =
      if company do
        case Attendance.list_allowance_rules(scope(socket), company.id) do
          {:ok, values} -> values
          _ -> nil
        end
      end

    {:noreply, socket |> assign(:company, company) |> assign(:rules, rules)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("select_company", %{"company_id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/people/attendance/rules/allowances?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("create", %{"rule" => attrs}, socket) do
    case Attendance.create_allowance_rule(scope(socket), company_id(socket), attrs) do
      {:ok, _rule} ->
        {:noreply, socket |> reload() |> put_flash(:success, "Allowance rule added.")}

      {:error, :effective_period_overlap} ->
        {:noreply,
         put_flash(socket, :error, "This code already has an overlapping effective period.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "Check the allowance rule fields and effective dates.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Allowance rules are unavailable for this company.")}
    end
  end

  def handle_event("retire", %{"id" => raw_id}, socket) do
    result =
      with {id, ""} <- Integer.parse(raw_id),
           do: Attendance.retire_allowance_rule(scope(socket), company_id(socket), id)

    updated(socket, result)
  end

  def handle_event("end_date", %{"rule_id" => raw_id, "effective_until" => raw_date}, socket) do
    result =
      with {id, ""} <- Integer.parse(raw_id),
           {:ok, until_date} <- Date.from_iso8601(raw_date),
           do: Attendance.end_allowance_rule(scope(socket), company_id(socket), id, until_date)

    updated(socket, result)
  end

  defp updated(socket, {:ok, _}),
    do: {:noreply, socket |> reload() |> put_flash(:success, "Allowance rule updated.")}

  defp updated(socket, _),
    do: {:noreply, put_flash(socket, :error, "Allowance rule could not be updated.")}

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.company.id

  defp reload(socket),
    do: handle_params(%{"company_id" => to_string(company_id(socket))}, nil, socket) |> elem(1)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, AttendanceComponents.input_class())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-allowances-page" variant={:form}>
        <.header>Allowance rules</.header>
        <AttendanceComponents.rules_tabs current={:allowances} company={@company} actor={@current_scope.actor} />
        <.empty_state :if={@company == nil} id="allowances-no-company"
          title="No active company is available for allowance rules." />
        <div :if={@company} class="mt-5">
          <AttendanceComponents.company_select id="allowance-company-form" companies={@companies} company={@company} />
        </div>
        <.empty_state :if={@company && @rules == nil} id="allowances-unavailable"
          title="Allowance rules are unavailable for this company."
          reason="The company's workforce is not current." />
        <div :if={@rules} class="mt-5 space-y-6">
          <section class="rounded-xl border border-line bg-surface p-4">
            <h2 class="font-semibold text-ink-strong">Add effective-dated rule</h2>
            <p class="mt-1 text-sm text-ink-muted">Use a company code and explicit currency. A later version ends the code's open version the day before it starts; active versions cannot overlap.</p>
            <form id="allowance-rule-form" phx-submit="create" class="mt-4 grid gap-3 sm:grid-cols-2">
              <label class="text-sm">Code<input name="rule[code]" required maxlength="40" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Name<input name="rule[name]" required maxlength="120" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Unit<input name="rule[unit]" required maxlength="32" placeholder="hour, shift, event" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Value<input name="rule[value]" required type="number" min="0.0001" step="0.0001" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Currency<input name="rule[currency]" required minlength="3" maxlength="3" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Effective from<input name="rule[effective_from]" required type="date" class={[@input, "mt-1 w-full"]} /></label>
              <label class="text-sm">Effective until<input name="rule[effective_until]" type="date" class={[@input, "mt-1 w-full"]} /></label>
              <div class="sm:col-span-2"><.button type="submit" variant="primary">Add rule</.button></div>
            </form>
          </section>
          <section>
            <h2 class="mb-2 font-semibold text-ink-strong">Rule history</h2>
            <div :if={@rules == []} class="rounded-xl border border-line bg-surface p-4 text-sm text-ink-muted">No allowance rules are configured.</div>
            <div :if={@rules != []} class="overflow-x-auto rounded-xl border border-line bg-surface">
              <table class="w-full text-sm">
                <thead class="bg-surface-sunken text-left text-xs font-semibold text-ink-subtle">
                  <tr><th class="px-2 py-1.5">Code</th><th class="px-2 py-1.5">Name</th><th class="px-2 py-1.5">Value</th><th class="px-2 py-1.5">Effective</th><th class="px-2 py-1.5">Status</th><th class="px-2 py-1.5">Action</th></tr>
                </thead>
                <tbody>
                  <tr :for={rule <- @rules} id={"allowance-rule-#{rule.id}"} class="border-t border-line">
                    <td class="px-2 py-1 tabular-nums">{rule.code}</td><td class="px-2 py-1">{rule.name}</td>
                    <td class="px-2 py-1 tabular-nums">{rule.value} {rule.currency} / {rule.unit}</td>
                    <td class="px-2 py-1 tabular-nums">{rule.effective_from} – {rule.effective_until || "Open"}</td>
                    <td class="px-2 py-1">{rule.status}</td>
                    <td class="px-2 py-1">
                      <div :if={rule.status == "active"} class="flex flex-wrap items-center gap-2">
                        <form phx-submit="end_date" class="flex items-center gap-2">
                          <input type="hidden" name="rule_id" value={rule.id} />
                          <input name="effective_until" type="date" required min={rule.effective_from} max={rule.effective_until} aria-label={"End date for #{rule.code}"} class={@input} />
                          <.button type="submit">End</.button>
                        </form>
                        <button type="button" phx-click="retire" phx-value-id={rule.id} class="text-link underline">Retire</button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
