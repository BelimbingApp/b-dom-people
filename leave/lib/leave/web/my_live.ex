defmodule Bilimbi.People.Leave.Web.MyLive do
  @moduledoc """
  Self leave balances, requests and cancellation for the signed-in actor.

  The facade resolves the actor's current linked employee and self-service
  grant on every read and write; nothing about the employee is kept here. A
  removed link shows the unavailable state on the next event.
  """
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Leave

  @day_parts [
    {"Full days", "full"},
    {"Morning (half day)", "am"},
    {"Afternoon (half day)", "pm"},
    {"Hours (hour-based types)", "hours"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My leave")
     |> assign(:active_nav, "people.leave.my")
     |> assign(:day_parts, @day_parts)
     |> new_request_key()
     |> load()}
  end

  @impl true
  def handle_event("submit_request", %{"request" => attrs}, socket) do
    %{scope: scope, actor: actor} = socket.assigns.current_scope

    attrs =
      attrs
      |> Map.take(~w(starts_on ends_on day_part hours reason))
      |> Map.reject(fn {_key, value} -> value == "" end)
      |> Map.put("leave_type_id", parse_integer(attrs["leave_type_id"]))
      |> Map.put("request_key", socket.assigns.request_key)

    case Leave.submit_request(scope, actor.company_id, attrs) do
      {:ok, _request} ->
        {:noreply,
         socket |> new_request_key() |> load() |> put_flash(:success, "Leave request submitted.")}

      {:error, reason} when reason in [:unauthorized, :not_linked] ->
        {:noreply, socket |> load() |> put_flash(:error, refusal(reason))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("cancel_request", %{"id" => id}, socket) do
    %{scope: scope, actor: actor} = socket.assigns.current_scope

    case Leave.cancel_request(scope, actor.company_id, parse_integer(id)) do
      {:ok, _request} ->
        {:noreply, socket |> load() |> put_flash(:success, "Leave request cancelled.")}

      {:error, reason} when reason in [:unauthorized, :not_linked] ->
        {:noreply, socket |> load() |> put_flash(:error, refusal(reason))}

      {:error, :year_closed} ->
        {:noreply,
         put_flash(socket, :error, "That leave year has been carried forward and is closed.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That request can no longer be cancelled.")}
    end
  end

  defp load(socket) do
    %{scope: scope, actor: actor} = socket.assigns.current_scope
    company_id = actor.company_id

    with {:ok, summary} <- Leave.self_summary(scope, company_id),
         {:ok, requests} <- Leave.self_requests(scope, company_id),
         {:ok, today} <- Leave.today(scope, company_id) do
      assign(socket, summary: summary, requests: requests, today: today)
    else
      _ -> assign(socket, summary: :unavailable, requests: [], today: nil)
    end
  end

  defp new_request_key(socket),
    do: assign(socket, :request_key, Base.url_encode64(:crypto.strong_rand_bytes(18)))

  defp refusal(:unauthorized), do: "You no longer have permission to use leave self-service."

  defp refusal(:not_linked),
    do: "Your account is not linked to a working employee in this company."

  defp refusal(:insufficient_balance), do: "The available balance does not cover this request."

  defp refusal(:overlapping_request),
    do: "Another pending or approved request already covers part of these dates."

  defp refusal(:no_working_days), do: "The chosen dates contain no working days."
  defp refusal(:spans_leave_years), do: "A request must fall within one leave year."
  defp refusal(:too_far_back), do: "The start date is further back than requests may start."
  defp refusal(:year_closed), do: "That leave year has been carried forward and is closed."

  defp refusal(_),
    do:
      "Choose an active leave type and valid dates; half days and hours cover a single date, and hours apply only to hour-based types."

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp cancellable?(%{status: "pending"}, _today), do: true

  defp cancellable?(%{status: "approved", starts_on: starts_on}, %Date{} = today),
    do: Date.compare(starts_on, today) == :gt

  defp cancellable?(_request, _today), do: false

  defp unit_label("hour"), do: "hours"
  defp unit_label(_), do: "days"

  defp part_label("am"), do: "morning"
  defp part_label("pm"), do: "afternoon"
  defp part_label(_), do: nil

  defp type_name(balances, type_id) do
    Enum.find_value(balances, "Leave", &(&1.leave_type.id == type_id && &1.leave_type.name))
  end

  defp open_types(balances),
    do: balances |> Enum.map(& &1.leave_type) |> Enum.filter(&(&1.status == "active"))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="my-leave-page">
        <.header>
          My leave
          <:subtitle :if={@summary != :unavailable}>
            Leave year {@summary.starts_on} to {@summary.ends_on}
          </:subtitle>
        </.header>
        <.empty_state :if={@summary == :unavailable} id="my-leave-unavailable"
          title="Leave is unavailable for this account."
          reason="Ask an operator to link your account to an active employee in this company." />
        <div :if={@summary != :unavailable} class="mt-5 space-y-6">
          <.empty_state :if={@summary.balances == []} id="my-leave-no-types"
            title="No leave types are set up yet."
            reason="Your balances will appear once an operator adds leave types and policies." />
          <.table :if={@summary.balances != []} id="my-leave-balances" rows={@summary.balances}
            row_id={&"leave-balance-#{&1.leave_type.id}"}>
            <:col :let={row} label="Leave type">{row.leave_type.name}</:col>
            <:col :let={row} label="Unit">{unit_label(row.leave_type.unit)}</:col>
            <:col :let={row} label="Entitlement" align={:right}>{row.entitlement}</:col>
            <:col :let={row} label="Carried in" align={:right}>{row.carried_forward}</:col>
            <:col :let={row} label="Opening" align={:right}>{row.opening}</:col>
            <:col :let={row} label="Adjustments" align={:right}>{row.adjustment}</:col>
            <:col :let={row} label="Taken" align={:right}>{row.taken}</:col>
            <:col :let={row} label="Balance" align={:right}>{row.balance}</:col>
            <:col :let={row} label="Pending" align={:right}>{row.pending}</:col>
            <:col :let={row} label="Available" align={:right}>{row.available}</:col>
          </.table>

          <section :if={open_types(@summary.balances) != []}
            class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Request leave</h2>
            <form id="leave-request-form" phx-submit="submit_request"
              class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <label class="grid gap-1 text-sm">
                Leave type
                <select name="request[leave_type_id]"
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm">
                  <option :for={type <- open_types(@summary.balances)} value={type.id}>
                    {type.name} ({unit_label(type.unit)})
                  </option>
                </select>
              </label>
              <label class="grid gap-1 text-sm">
                From
                <input type="date" name="request[starts_on]" required
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              </label>
              <label class="grid gap-1 text-sm">
                To
                <input type="date" name="request[ends_on]"
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              </label>
              <label class="grid gap-1 text-sm">
                Duration
                <select name="request[day_part]"
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm">
                  <option :for={{label, value} <- @day_parts} value={value}>{label}</option>
                </select>
              </label>
              <label class="grid gap-1 text-sm">
                Hours
                <input name="request[hours]" inputmode="decimal" placeholder="Only for hours"
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              </label>
              <label class="grid gap-1 text-sm">
                Reason
                <input name="request[reason]" maxlength="500"
                  class="rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              </label>
              <div class="sm:col-span-2 lg:col-span-3">
                <.button type="submit">Submit request</.button>
              </div>
            </form>
            <p class="mt-2 text-sm text-ink-muted">
              Leave counts only this company's working days; pending requests hold their quantity
              until they are decided. Leave "To" empty for a single day.
            </p>
          </section>

          <section :if={@summary.balances != []}>
            <h2 class="text-base font-semibold text-ink">My requests</h2>
            <p :if={@requests == []} id="my-leave-no-requests" class="mt-2 text-sm text-ink-muted">
              You have not requested any leave yet.
            </p>
            <ul :if={@requests != []} id="my-leave-requests" class="mt-2 space-y-2">
              <li :for={request <- @requests} id={"leave-request-#{request.id}"}
                class="flex flex-wrap items-center gap-2 rounded-lg border border-line bg-surface p-3 text-sm">
                <strong>{request.starts_on}</strong>
                <span :if={request.ends_on != request.starts_on}>to {request.ends_on}</span>
                · {type_name(@summary.balances, request.leave_type_id)}
                · {request.quantity} {unit_label(request.unit)}
                <span :if={part_label(request.day_part)}>({part_label(request.day_part)})</span>
                · <span class="font-medium">{request.status}</span>
                <span :if={request.decision_note} class="text-ink-muted">· {request.decision_note}</span>
                <button :if={cancellable?(request, @today)} type="button"
                  class="ml-auto text-sm underline" phx-click="cancel_request"
                  phx-value-id={request.id}>
                  Cancel
                </button>
              </li>
            </ul>
          </section>

          <section :if={@summary.balances != []}>
            <h2 class="text-base font-semibold text-ink">Balance history</h2>
            <p :if={@summary.entries == []} id="my-leave-no-entries" class="mt-2 text-sm text-ink-muted">
              No entitlements or adjustments have been recorded for this leave year.
            </p>
            <ul :if={@summary.entries != []} class="mt-2 space-y-2">
              <li :for={entry <- @summary.entries} class="rounded-lg border border-line bg-surface p-3 text-sm">
                <strong>{entry.occurred_on}</strong> · {type_name(@summary.balances, entry.leave_type_id)} ·
                {entry.entry_type} · {entry.quantity} {unit_label(entry.unit)}
                <span :if={entry.note} class="text-ink-muted">· {entry.note}</span>
              </li>
            </ul>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
