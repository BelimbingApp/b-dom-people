defmodule Bilimbi.People.Attendance.Web.ApprovalsLive do
  @moduledoc """
  Pending attendance adjustment requests for one company. Approving writes the
  requested clock event; the requester and their own employee cannot decide.
  """
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents
  @capability "people.attendance.adjustments.approve"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Attendance approvals")
     |> assign(:active_nav, "people.attendance.approvals")
     |> assign(
       :companies,
       AttendanceComponents.companies(socket.assigns.current_scope.scope, @capability)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = AttendanceComponents.pick(socket.assigns.companies, params["company_id"])
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/attendance/approvals?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket), do: {:noreply, socket}

  def handle_event("decide", %{"request_id" => id, "decision" => decision} = params, socket)
      when decision in ["approve", "reject"] do
    with {id, ""} <- Integer.parse(id),
         {:ok, _} <-
           Attendance.decide_adjustment(
             socket.assigns.current_scope.scope,
             socket.assigns.company.id,
             id,
             String.to_existing_atom(decision),
             params["note"]
           ) do
      message = if decision == "approve", do: "Request approved.", else: "Request rejected."
      {:noreply, socket |> load() |> put_flash(:success, message)}
    else
      {:error, reason} -> {:noreply, socket |> load() |> put_flash(:error, refusal(reason))}
      _ -> {:noreply, put_flash(socket, :error, refusal(:not_found))}
    end
  end

  def refusal(:self_approval), do: "You cannot decide your own attendance request."

  def refusal(:unauthorized),
    do: "You no longer have permission to decide attendance requests for this company."

  def refusal(:note_required), do: "Add a note explaining the rejection."
  def refusal(:note_too_long), do: "Keep the note within 500 characters."
  def refusal(:not_pending), do: "This request has already been decided."
  def refusal(:employee_unavailable), do: "The employee is no longer working in this company."
  def refusal(:event_key_conflict), do: "The clock event could not be recorded."
  def refusal(_), do: "The request could not be decided."

  defp load(%{assigns: %{company: nil}} = socket), do: assign(socket, :requests, nil)

  defp load(socket) do
    requests =
      case Attendance.pending_adjustments(
             socket.assigns.current_scope.scope,
             socket.assigns.company.id
           ) do
        {:ok, values} -> values
        _ -> nil
      end

    assign(socket, :requests, requests)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, AttendanceComponents.input_class())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-approvals-page">
        <.header>
          Attendance approvals
          <:subtitle>Missing clock events employees asked to add.</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="attendance-approvals-no-company" class="mt-5"
          title="No active company is available for attendance approvals." />
        <div :if={@company} class="mt-5 space-y-4">
          <div class="max-w-md">
            <AttendanceComponents.company_select id="attendance-approvals-company" companies={@companies} company={@company} />
          </div>
          <.empty_state :if={@requests == nil} id="attendance-approvals-unavailable"
            title="Approvals are unavailable for this company."
            reason="The company's workforce is not current." />
          <.empty_state :if={@requests == []} id="attendance-approvals-empty"
            title="No adjustment requests are waiting." reason="New requests from employees will appear here." />
          <ul :if={@requests not in [nil, []]} class="space-y-3">
            <li :for={%{request: request, employee_name: name} <- @requests} id={"adjustment-#{request.id}"}
              class="rounded-lg border border-line bg-surface p-3">
              <p class="font-medium">{name || "Employee no longer working"}</p>
              <p class="text-sm text-ink-muted">
                {AttendanceComponents.clock_label(request.event_type)} at
                {AttendanceComponents.local_time(request.proposed_at, request.timezone)} ({request.timezone})
              </p>
              <p class="mt-1 text-sm">{request.reason}</p>
              <form id={"adjustment-decision-#{request.id}"} phx-submit="decide" class="mt-2 flex flex-wrap gap-2">
                <input type="hidden" name="request_id" value={request.id} />
                <input name="note" aria-label="Decision note" placeholder="Note (required to reject)" maxlength="500"
                  class={["min-w-0 flex-1", @input]} />
                <.button type="submit" name="decision" value="approve" variant="primary">Approve</.button>
                <.button type="submit" name="decision" value="reject">Reject</.button>
              </form>
            </li>
          </ul>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
