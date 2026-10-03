defmodule Bilimbi.People.Leave.Web.ApprovalsLive do
  @moduledoc "Pending leave requests of an authorized company, approved or rejected by an independent approver."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Leave
  @capability "people.leave.requests.approve"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Leave approvals")
     |> assign(:active_nav, "people.leave.approvals")
     |> assign(:companies, companies)
     |> select_company(nil)}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, select_company(socket, id)}

  def handle_event("decide", %{"request_id" => id, "decision" => decision} = params, socket)
      when decision in ["approve", "reject"] do
    case socket.assigns.company do
      nil ->
        {:noreply, socket}

      company ->
        result =
          Leave.decide_request(
            socket.assigns.current_scope.scope,
            company.id,
            parse_integer(id),
            String.to_existing_atom(decision),
            params["note"]
          )

        {:noreply, socket |> load() |> put_flash(flash_kind(result), message(result, decision))}
    end
  end

  defp flash_kind({:ok, _}), do: :success
  defp flash_kind(_), do: :error

  defp message({:ok, _}, "approve"), do: "Leave request approved."
  defp message({:ok, _}, "reject"), do: "Leave request rejected."
  defp message({:error, :note_required}, _), do: "Give a reason when rejecting a request."
  defp message({:error, :self_approval}, _), do: "You cannot decide your own leave request."

  defp message({:error, :insufficient_balance}, _),
    do: "The employee's available balance no longer covers this request."

  defp message({:error, :year_closed}, _),
    do: "That leave year has been carried forward and is closed."

  defp message({:error, :not_pending}, _), do: "That request has already been decided."

  defp message({:error, :unauthorized}, _),
    do: "You no longer have permission to decide leave requests for this company."

  defp message(_, _), do: "The request could not be decided."

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

  defp load(%{assigns: %{company: nil}} = socket),
    do: assign(socket, requests: :unavailable, types: [])

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    with {:ok, requests} <- Leave.pending_requests(scope, company_id),
         {:ok, types} <- Leave.list_types(scope, company_id) do
      assign(socket, requests: requests, types: types)
    else
      {:error, :unauthorized} -> assign(socket, requests: :unauthorized, types: [])
      _ -> assign(socket, requests: :unavailable, types: [])
    end
  end

  defp type_name(types, id), do: Enum.find_value(types, "Leave", &(&1.id == id && &1.name))
  defp unit_label("hour"), do: "hours"
  defp unit_label(_), do: "days"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="leave-approvals-page">
        <.header>
          Leave approvals
          <:subtitle :if={@company}>{@company.name} · Pending requests</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="leave-approvals-empty"
          title="No active company is available for leave approvals." />
        <form :if={@company} phx-change="select_company" id="leave-approvals-company-form">
          <label for="leave-approvals-company">Company</label>
          <select id="leave-approvals-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && @requests == :unavailable} id="leave-approvals-unavailable"
          title="Leave requests are unavailable for this company."
          reason="Workforce data for this company is not current." />
        <.empty_state :if={@company && @requests == :unauthorized} id="leave-approvals-forbidden"
          title="Leave requests are unavailable for this company."
          reason="You no longer have permission to decide leave requests here." />
        <p :if={@requests == []} id="leave-approvals-none" class="mt-5 text-sm text-ink-muted">
          No leave requests are waiting for a decision.
        </p>
        <ul :if={is_list(@requests) and @requests != []} id="leave-approvals" class="mt-5 space-y-3">
          <li :for={request <- @requests} id={"leave-approval-#{request.id}"}
            class="rounded-xl border border-line bg-surface p-4 text-sm">
            <div class="flex flex-wrap gap-2">
              <strong>{request.employee_name || "Employee #{request.employee_id}"}</strong>
              · {type_name(@types, request.leave_type_id)}
              · {request.starts_on}<span :if={request.ends_on != request.starts_on}> to {request.ends_on}</span>
              · {request.quantity} {unit_label(request.unit)}
            </div>
            <p :if={request.reason} class="mt-1 text-ink-muted">{request.reason}</p>
            <form id={"leave-decision-#{request.id}"} phx-submit="decide"
              class="mt-3 flex flex-wrap items-end gap-2">
              <input type="hidden" name="request_id" value={request.id} />
              <input name="note" maxlength="500" aria-label="Decision note"
                placeholder="Note (required to reject)"
                class="min-w-0 flex-1 rounded-md border border-line bg-surface px-3 py-2 text-sm" />
              <.button type="submit" name="decision" value="approve">Approve</.button>
              <.button type="submit" name="decision" value="reject">Reject</.button>
            </form>
          </li>
        </ul>
      </.page>
    </Layouts.app>
    """
  end
end
