defmodule Bilimbi.People.Leave.Web.MyLive do
  @moduledoc "Self leave balances with account-to-employee resolution through Core User."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Leave

  @impl true
  def mount(_params, _session, socket) do
    current = socket.assigns.current_scope

    summary =
      case Leave.self_summary(current.scope, current.actor.company_id, current.actor) do
        {:ok, value} -> value
        _ -> :unavailable
      end

    {:ok,
     socket
     |> assign(:page_title, "My leave")
     |> assign(:active_nav, "people.leave.my")
     |> assign(:summary, summary)}
  end

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
            <:col :let={row} label="Opening" align={:right}>{row.opening}</:col>
            <:col :let={row} label="Adjustments" align={:right}>{row.adjustment}</:col>
            <:col :let={row} label="Balance" align={:right}>{row.balance}</:col>
          </.table>
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

  defp unit_label("hour"), do: "hours"
  defp unit_label(_), do: "days"

  defp type_name(balances, type_id) do
    Enum.find_value(balances, "Leave", &(&1.leave_type.id == type_id && &1.leave_type.name))
  end
end
