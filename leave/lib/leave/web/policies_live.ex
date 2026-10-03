defmodule Bilimbi.People.Leave.Web.PoliciesLive do
  @moduledoc "Operator-managed company leave year, request rules, types, policy versions, grants and carry-forward."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Leave
  @capability "people.leave.policies.manage"
  @months ~w(January February March April May June July August September October November December)
  @weekdays Enum.zip(~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday), 1..7)

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Leave policies")
     |> assign(:active_nav, "people.leave.policies")
     |> assign(:months, Enum.with_index(@months, 1))
     |> assign(:weekdays, @weekdays)
     |> assign(:companies, companies)
     |> select_company(nil)}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, select_company(socket, id)}

  def handle_event("save_year", %{"year_start_month" => month}, socket) do
    with_company(socket, fn company ->
      case Leave.put_rules(scope(socket), company.id, parse_integer(month)) do
        {:ok, _} ->
          socket |> load() |> put_flash(:success, "Leave year saved.")

        {:error, :unauthorized} ->
          forbidden(socket)

        {:error, :year_in_use} ->
          put_flash(
            socket,
            :error,
            "The leave year cannot change after balances have been recorded."
          )

        _ ->
          put_flash(socket, :error, "Choose a month for the leave year.")
      end
    end)
  end

  def handle_event("save_request_rules", params, socket) do
    with_company(socket, fn company ->
      weekdays =
        params |> Map.get("working_weekdays", []) |> List.wrap() |> Enum.map(&parse_integer/1)

      case Leave.put_request_rules(scope(socket), company.id, %{
             working_weekdays: weekdays,
             backdate_days: parse_integer(params["backdate_days"])
           }) do
        {:ok, _} ->
          socket |> load() |> put_flash(:success, "Request rules saved.")

        {:error, :unauthorized} ->
          forbidden(socket)

        _ ->
          put_flash(
            socket,
            :error,
            "Choose at least one working weekday and a backdating limit of 0 to 366 days."
          )
      end
    end)
  end

  def handle_event("carry_forward", %{"from_year" => year}, socket) do
    with_company(socket, fn company ->
      case Leave.enqueue_carry_forward(scope(socket), company.id, parse_integer(year)) do
        :ok ->
          put_flash(
            socket,
            :success,
            "Carry-forward queued. Balances update once it runs; running it again changes nothing."
          )

        {:error, :unauthorized} ->
          forbidden(socket)

        _ ->
          put_flash(socket, :error, "Carry-forward could not be queued for that year.")
      end
    end)
  end

  def handle_event("create_type", %{"type" => attrs}, socket) do
    with_company(socket, fn company ->
      attrs =
        attrs
        |> Map.put("paid", Map.get(attrs, "paid") == "true")
        |> Map.put("balance_required", Map.get(attrs, "balance_required") == "true")

      case Leave.create_type(scope(socket), company.id, attrs) do
        {:ok, _} ->
          socket |> load() |> put_flash(:success, "Leave type added.")

        {:error, :unauthorized} ->
          forbidden(socket)

        _ ->
          put_flash(
            socket,
            :error,
            "Enter a unique lowercase code, a name and a unit for the leave type."
          )
      end
    end)
  end

  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with_company(socket, fn company ->
      case Leave.set_type_status(scope(socket), company.id, parse_integer(id), status) do
        {:ok, _} -> socket |> load() |> put_flash(:success, "Leave type updated.")
        {:error, :unauthorized} -> forbidden(socket)
        _ -> put_flash(socket, :error, "The leave type could not be updated.")
      end
    end)
  end

  def handle_event("add_policy", %{"policy" => attrs}, socket) do
    with_company(socket, fn company ->
      case Leave.add_policy(
             scope(socket),
             company.id,
             parse_integer(attrs["leave_type_id"]),
             attrs
           ) do
        {:ok, _} ->
          socket |> load() |> put_flash(:success, "Policy version added.")

        {:error, :unauthorized} ->
          forbidden(socket)

        {:error, :not_after_latest} ->
          put_flash(socket, :error, "A new version must start after the latest version.")

        {:error, :granted_after_effective_date} ->
          put_flash(
            socket,
            :error,
            "Entitlements were already granted on or after that date; start the version later."
          )

        _ ->
          put_flash(
            socket,
            :error,
            "Choose an active leave type, a start date, an entitlement of 0 to 9999.99 and an optional carry-forward cap in the same range."
          )
      end
    end)
  end

  def handle_event("grant", %{"leave_year" => year}, socket) do
    with_company(socket, fn company ->
      case Leave.grant_entitlements(scope(socket), company.id, parse_integer(year)) do
        {:ok, %{granted: granted, existing: existing, closed: closed}} ->
          put_flash(
            socket,
            :success,
            "#{granted} entitlements granted; #{existing} were already granted; " <>
              "#{closed} skipped because the year is carried forward."
          )

        {:error, :unauthorized} ->
          forbidden(socket)

        _ ->
          put_flash(socket, :error, "Entitlements could not be granted for that year.")
      end
    end)
  end

  defp with_company(socket, fun) do
    case socket.assigns.company do
      nil -> {:noreply, socket}
      company -> {:noreply, fun.(company)}
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  # The facade decides each write with the actor's current grant; the page
  # only reports the refusal and shows what it may still read.
  defp forbidden(socket),
    do:
      socket
      |> load()
      |> put_flash(
        :error,
        "You no longer have permission to change this company's leave policies."
      )

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp select_company(socket, id) do
    company =
      Enum.find(socket.assigns.companies, &(id == Integer.to_string(&1.id))) ||
        List.first(socket.assigns.companies)

    socket |> assign(:company, company) |> load()
  end

  defp load(%{assigns: %{company: nil}} = socket), do: assign(socket, empty_assigns())

  defp load(socket) do
    company_id = socket.assigns.company.id

    with {:ok, rules} <- Leave.rules(scope(socket), company_id),
         {:ok, types} <- Leave.list_types(scope(socket), company_id),
         {:ok, policies} <- Leave.list_policies(scope(socket), company_id),
         {:ok, request_rules} <- Leave.request_rules(scope(socket), company_id),
         {:ok, today} <- Leave.today(scope(socket), company_id),
         current_year = Leave.leave_year(rules, today),
         {:ok, carried} <-
           Leave.carried_forward_count(scope(socket), company_id, current_year - 1),
         {:ok, skipped} <- skipped(scope(socket), company_id) do
      assign(socket,
        rules: rules,
        request_rules: request_rules,
        types: types,
        policies: policies,
        current_year: current_year,
        carried_count: carried,
        carry_skipped: Enum.chunk_by(skipped.skips, & &1.from_year),
        carry_skipped_shown: length(skipped.skips),
        carry_skipped_total: skipped.total
      )
    else
      _ -> assign(socket, empty_assigns())
    end
  end

  # The skip report names employees, so it needs the manage grant now; a page
  # that lost it still shows the company's rules and types.
  defp skipped(scope, company_id) do
    case Leave.carry_forward_skipped(scope, company_id) do
      {:ok, skipped} -> {:ok, skipped}
      {:error, :unauthorized} -> {:ok, %{skips: [], total: 0}}
      error -> error
    end
  end

  defp empty_assigns,
    do: [
      rules: nil,
      request_rules: nil,
      types: [],
      policies: [],
      current_year: nil,
      carried_count: 0,
      carry_skipped: [],
      carry_skipped_shown: 0,
      carry_skipped_total: 0
    ]

  defp type_name(types, id), do: Enum.find_value(types, "Leave", &(&1.id == id && &1.name))

  defp skip_reason(%{reason: :pending, blocking_year: year}),
    do: "has a pending request in leave year #{year}"

  defp skip_reason(%{reason: :previous_year_open, blocking_year: year}),
    do: "leave year #{year} is not carried forward yet"

  defp unit_label("hour"), do: "hours"
  defp unit_label(_), do: "days"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="leave-policies-page">
        <.header>
          Leave policies
          <:subtitle :if={@company}>{@company.name} · Leave year, types and entitlements</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="leave-policies-empty"
          title="No active company is available for leave policies." />
        <form :if={@company} phx-change="select_company" id="leave-company-form">
          <label for="leave-company">Company</label>
          <select id="leave-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>

        <.empty_state :if={@company && @rules == nil} id="leave-policies-unavailable"
          title="Leave policies are unavailable for this company." />

        <div :if={@rules} class="mt-5 grid gap-5 lg:grid-cols-2">
          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Leave year</h2>
            <form id="leave-year-form" phx-submit="save_year" class="mt-3 flex flex-wrap items-end gap-2">
              <label for="leave-year-start" class="text-sm">Starts in</label>
              <select id="leave-year-start" name="year_start_month"
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm">
                <option :for={{name, month} <- @months} value={month}
                  selected={month == @rules.year_start_month}>{name}</option>
              </select>
              <.button type="submit">Save leave year</.button>
            </form>
            <form id="leave-grant-form" phx-submit="grant" class="mt-5 flex flex-wrap items-end gap-2">
              <label for="leave-grant-year" class="text-sm">Grant entitlements for leave year</label>
              <input id="leave-grant-year" name="leave_year" type="number" min="1900" max="9998"
                value={@current_year} required
                class="w-28 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <.button type="submit" disabled={@policies == []}>Grant</.button>
            </form>
            <p class="mt-2 text-sm text-ink-muted">
              Each current employee receives each active type's entitlement from the version in force
              on the first day of that leave year. Repeating a grant changes nothing.
            </p>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Request rules</h2>
            <form id="leave-request-rules-form" phx-submit="save_request_rules" class="mt-3 space-y-3">
              <fieldset>
                <legend class="text-sm">Working weekdays counted as leave</legend>
                <div class="mt-1 flex flex-wrap gap-3">
                  <label :for={{name, day} <- @weekdays} class="flex items-center gap-1 text-sm">
                    <input type="checkbox" name="working_weekdays[]" value={day}
                      checked={day in @request_rules.working_weekdays} />{name}
                  </label>
                </div>
              </fieldset>
              <label class="flex flex-wrap items-center gap-2 text-sm">
                Requests may start up to
                <input name="backdate_days" type="number" min="0" max="366" required
                  value={@request_rules.backdate_days}
                  class="w-24 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
                days before today
              </label>
              <.button type="submit">Save request rules</.button>
            </form>
            <p class="mt-2 text-sm text-ink-muted">
              Calendar exceptions in People references are never counted as leave days.
            </p>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Year-end carry-forward</h2>
            <form id="leave-carry-forward-form" phx-submit="carry_forward"
              class="mt-3 flex flex-wrap items-end gap-2">
              <label for="leave-carry-year" class="text-sm">Carry forward from leave year</label>
              <input id="leave-carry-year" name="from_year" type="number" min="1900" max="9997"
                value={@current_year - 1} required
                class="w-28 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <.button type="submit">Queue carry-forward</.button>
            </form>
            <p id="leave-carried-count" class="mt-2 text-sm text-ink-muted">
              {@carried_count} balances from leave year {@current_year - 1} have been carried forward.
            </p>
            <div :if={@carry_skipped != []} id="leave-carry-skipped" class="mt-2 space-y-2">
              <p :if={@carry_skipped_shown < @carry_skipped_total} id="leave-carry-skipped-truncated"
                class="text-sm text-ink-muted">
                Showing {@carry_skipped_shown} of {@carry_skipped_total} skipped balances, oldest
                leave year first.
              </p>
              <div :for={[%{from_year: year} | _] = skips <- @carry_skipped}
                id={"leave-carry-skipped-#{year}"}>
                <h3 class="text-sm font-medium text-ink">Skipped from leave year {year}</h3>
                <ul class="mt-1 space-y-1 text-sm text-ink-muted">
                  <li :for={skip <- skips}
                    id={"leave-carry-skipped-#{year}-#{skip.employee_id}-#{skip.leave_type_id}"}>
                    {skip.employee_name} · {skip.leave_type_name} · {skip_reason(skip)}
                  </li>
                </ul>
              </div>
            </div>
            <p class="mt-2 text-sm text-ink-muted">
              For each type whose policy on the year's last day sets a cap, each current employee's
              closing balance up to the cap moves into the next year and the rest expires. The year
              must have ended, and years are carried in order. Each year's latest run lists the employees
              it skipped: those with a pending request in the year, or with an earlier year not carried
              forward yet, naming the year to resolve. Run the years again, oldest first, once that
              is resolved. A carried year, and every year
              before it, is closed to new requests and entries.
            </p>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Leave types</h2>
            <p :if={@types == []} id="leave-types-empty" class="mt-3 text-sm text-ink-muted">
              No leave types have been added for this company.
            </p>
            <ul :if={@types != []} id="leave-types" class="mt-3 divide-y divide-line text-sm">
              <li :for={type <- @types} id={"leave-type-#{type.id}"} class="flex items-center gap-2 py-2">
                <span class="font-medium">{type.name}</span>
                <span class="text-ink-muted">{type.code} · {unit_label(type.unit)} · {if type.paid, do: "paid", else: "unpaid"}</span>
                <span :if={!type.balance_required} class="text-ink-muted">· may go negative</span>
                <span :if={type.status == "archived"} class="text-ink-muted">· archived</span>
                <button type="button" class="ml-auto text-sm underline"
                  phx-click="set_status" phx-value-id={type.id}
                  phx-value-status={if type.status == "active", do: "archived", else: "active"}>
                  {if type.status == "active", do: "Archive", else: "Restore"}
                </button>
              </li>
            </ul>
            <form id="leave-type-form" phx-submit="create_type" class="mt-4 grid gap-2 sm:grid-cols-2">
              <input name="type[code]" aria-label="Leave type code" placeholder="Code" required maxlength="40"
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <input name="type[name]" aria-label="Leave type name" placeholder="Name" required maxlength="120"
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <select name="type[unit]" aria-label="Leave type unit"
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm">
                <option value="day">Days</option>
                <option value="hour">Hours</option>
              </select>
              <label class="flex items-center gap-2 text-sm">
                <input type="checkbox" name="type[paid]" value="true" checked />Paid leave
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input type="checkbox" name="type[balance_required]" value="true" checked />
                Requests need an available balance
              </label>
              <.button type="submit">Add leave type</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Entitlement policy versions</h2>
            <p :if={@policies == []} id="leave-policies-none" class="mt-3 text-sm text-ink-muted">
              No policy versions have been added. Add a leave type, then its first version.
            </p>
            <.table :if={@policies != []} id="leave-policy-versions" rows={@policies}
              row_id={&"leave-policy-#{&1.id}"}>
              <:col :let={policy} label="Leave type">{type_name(@types, policy.leave_type_id)}</:col>
              <:col :let={policy} label="Version" align={:right}>{policy.version}</:col>
              <:col :let={policy} label="Effective from">{policy.effective_from}</:col>
              <:col :let={policy} label="Effective to">{policy.effective_to || "Open"}</:col>
              <:col :let={policy} label="Entitlement per year" align={:right}>{policy.entitlement}</:col>
              <:col :let={policy} label="Carry-forward cap" align={:right}>
                {policy.carry_forward_cap || "No carry-forward"}
              </:col>
            </.table>
            <form :if={Enum.any?(@types, &(&1.status == "active"))} id="leave-policy-form"
              phx-submit="add_policy" class="mt-4 flex flex-wrap items-end gap-2">
              <select name="policy[leave_type_id]" aria-label="Leave type for policy"
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm">
                <option :for={type <- @types} :if={type.status == "active"} value={type.id}>{type.name}</option>
              </select>
              <input type="date" name="policy[effective_from]" aria-label="Effective from" required
                class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <input name="policy[entitlement]" aria-label="Entitlement per year" placeholder="Entitlement"
                inputmode="decimal" required
                class="w-32 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <input name="policy[carry_forward_cap]" aria-label="Carry-forward cap"
                placeholder="Carry-forward cap" inputmode="decimal"
                class="w-40 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <.button type="submit">Add version</.button>
            </form>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
