defmodule Bilimbi.People.Claims.Web.OperationsLive do
  @moduledoc """
  Operator queue for one company's claims: decisions, reimbursement, and
  hand-off batches.

  The company list comes from `Authorization.selectable_companies/2` under the
  route capability `people.claims.approve`. Paying and handing off need
  `people.claims.reimburse`, rechecked for the selected company on every such
  action. Each irreversible action is held until the operator confirms it.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Claims

  @approve "people.claims.approve"
  @reimburse "people.claims.reimburse"
  @tabs ~w(submitted approved reimbursed rejected batches)

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Authorization.selectable_companies(socket.assigns.current_scope.scope, @approve) do
        {:ok, companies} -> companies
        {:error, :unauthorized} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Claim operations")
     |> assign(:companies, companies)
     |> assign(:pending, nil)
     |> assign(:export, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "submitted"

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:pending, nil)
     |> assign(:export, nil)
     |> select_company(Map.get(params, "company_id"))}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => company_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/people/claims/operations?company_id=#{company_id}")}
  end

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("decide", %{"request_id" => raw_id, "decision" => decision} = params, socket)
      when decision in ["approve", "reject"] do
    attrs = Map.take(params, ["approved_amount", "decision_reason"])

    with true <- authorized?(socket, @approve),
         %{} = request <- find(socket, raw_id),
         :ok <- reason_given(decision, attrs) do
      {:noreply, assign(socket, :pending, {String.to_existing_atom(decision), request, attrs})}
    else
      {:error, :reason_required} ->
        {:noreply, put_flash(socket, :error, refusal(:reason_required))}

      _ ->
        {:noreply, put_flash(socket, :error, "This claim is no longer awaiting a decision.")}
    end
  end

  def handle_event("reimburse", %{"request_id" => raw_id} = params, socket) do
    with true <- authorized?(socket, @reimburse),
         %{} = request <- find(socket, raw_id) do
      attrs = Map.take(params, ["payment_reference"])
      {:noreply, assign(socket, :pending, {:reimburse, request, attrs})}
    else
      _ -> {:noreply, put_flash(socket, :error, "This claim cannot be reimbursed.")}
    end
  end

  def handle_event("handoff", %{"currency" => currency}, socket) do
    if authorized?(socket, @reimburse),
      do: {:noreply, assign(socket, :pending, {:handoff, currency, %{}})},
      else: {:noreply, put_flash(socket, :error, "You may not hand off claims.")}
  end

  def handle_event("reimburse_batch", %{"batch_id" => raw_id} = params, socket) do
    with true <- authorized?(socket, @reimburse),
         %{} = batch <- Enum.find(socket.assigns.batches, &(Integer.to_string(&1.id) == raw_id)) do
      attrs = Map.take(params, ["payment_reference"])
      {:noreply, assign(socket, :pending, {:reimburse_batch, batch, attrs})}
    else
      _ -> {:noreply, put_flash(socket, :error, "This batch cannot be reimbursed.")}
    end
  end

  def handle_event("export", %{"id" => raw_id}, socket) do
    with true <- authorized?(socket, @reimburse),
         {id, ""} <- Integer.parse(raw_id),
         {:ok, export} <- Claims.handoff_export(scope(socket), company_id(socket), id) do
      {:noreply, assign(socket, :export, Map.put(export, :batch_id, id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "This batch cannot be exported.")}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :pending, nil)}

  def handle_event("confirm", _params, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm", _params, %{assigns: %{pending: pending}} = socket) do
    socket = assign(socket, :pending, nil)

    if authorized?(socket, capability(pending)) do
      case run(pending, socket) do
        {:ok, message} ->
          {:noreply, socket |> load() |> clear_flash(:error) |> put_flash(:info, message)}

        {:error, reason} ->
          {:noreply, socket |> load() |> clear_flash(:info) |> put_flash(:error, refusal(reason))}
      end
    else
      # Reloading through the facade drops the queue the actor may no longer read.
      {:noreply,
       socket
       |> load()
       |> put_flash(:error, "You are not allowed to do that for this company.")}
    end
  end

  defp reason_given("reject", attrs) do
    if String.trim(Map.get(attrs, "decision_reason", "")) == "",
      do: {:error, :reason_required},
      else: :ok
  end

  defp reason_given(_decision, _attrs), do: :ok

  defp capability({action, _subject, _attrs}) when action in [:approve, :reject], do: @approve
  defp capability(_pending), do: @reimburse

  # The facade authorizes each action for the scope's actor when it runs and
  # records who performed it; the page passes no actor.
  defp run({:approve, request, attrs}, socket) do
    Claims.approve_request(scope(socket), company_id(socket), request.id, attrs)
    |> result("Claim approved.")
  end

  defp run({:reject, request, attrs}, socket) do
    Claims.reject_request(scope(socket), company_id(socket), request.id, attrs)
    |> result("Claim rejected.")
  end

  defp run({:reimburse, request, attrs}, socket) do
    Claims.reimburse_request(scope(socket), company_id(socket), request.id, attrs)
    |> result("Claim marked reimbursed.")
  end

  defp run({:handoff, currency, _attrs}, socket) do
    Claims.create_handoff_batch(scope(socket), company_id(socket), currency)
    |> result("Hand-off batch created. Open it under Batches to export it.")
  end

  defp run({:reimburse_batch, batch, attrs}, socket) do
    Claims.reimburse_batch(scope(socket), company_id(socket), batch.id, attrs)
    |> result("Batch claims marked reimbursed.")
  end

  defp result({:ok, _value}, message), do: {:ok, message}
  defp result({:error, reason}, _message), do: {:error, reason}

  @doc "Operator-facing text for a refused action."
  def refusal(:own_claim), do: "You cannot act on your own claim."
  def refusal(:not_decidable), do: "This claim is no longer in the right state for that action."
  def refusal(:nothing_to_hand_off), do: "No approved claims in that currency are waiting."
  def refusal(:nothing_to_reimburse), do: "No approved claims are left in this batch."
  def refusal(:not_found), do: "That record is no longer available."

  def refusal(:unauthorized),
    do: "You no longer have permission to do that for this company's claims."

  def refusal(:reason_required), do: "Enter a reason before rejecting a claim."

  def refusal(%Ecto.Changeset{errors: errors}) do
    cond do
      Keyword.has_key?(errors, :decision_reason) -> "Enter a reason for this decision."
      Keyword.has_key?(errors, :approved_amount) -> "Check the approved amount: up to the claim."
      true -> "Check the values entered."
    end
  end

  def refusal(_reason), do: "The action could not be completed."

  defp authorized?(socket, capability) do
    Enum.all?([@approve, capability], fn required ->
      match?(
        {:ok, _company},
        Authorization.authorize_company(
          socket.assigns.current_scope.scope,
          company_id(socket),
          required
        )
      )
    end)
  end

  defp find(socket, raw_id),
    do: Enum.find(socket.assigns.rows, &(Integer.to_string(&1.id) == raw_id))

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do: socket |> assign(:company, nil) |> clear()

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))

    socket
    |> assign(:company, company)
    |> assign(:can_reimburse, authorized?(assign(socket, :company, company), @reimburse))
    |> load()
  end

  defp load(%{assigns: %{tab: "batches"}} = socket) do
    case Claims.handoff_batches(scope(socket), company_id(socket)) do
      {:ok, batches} ->
        socket |> assign(rows: [], waiting: [], export: nil) |> assign(:batches, batches)

      _ ->
        socket |> assign(:company, nil) |> clear()
    end
  end

  defp load(socket) do
    with {:ok, rows} <- Claims.claim_queue(scope(socket), company_id(socket), socket.assigns.tab),
         {:ok, batches} <- Claims.handoff_batches(scope(socket), company_id(socket)) do
      socket
      |> assign(:rows, rows)
      |> assign(:batches, batches)
      |> assign(:waiting, waiting(socket))
    else
      _ -> socket |> assign(:company, nil) |> clear()
    end
  end

  # Approved claims that no batch holds yet, per currency.
  defp waiting(%{assigns: %{tab: "approved"}} = socket) do
    case Claims.handoff_waiting(scope(socket), company_id(socket)) do
      {:ok, waiting} -> waiting
      _ -> []
    end
  end

  defp waiting(_socket), do: []

  defp clear(socket),
    do: assign(socket, rows: [], batches: [], waiting: [], can_reimburse: false, export: nil)

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.company.id

  defp money(nil), do: "—"
  defp money(value), do: Decimal.to_string(value)

  defp moment(nil), do: "—"
  defp moment(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp data_link(%{content: content}),
    do: "data:text/csv;charset=utf-8," <> URI.encode(content, &URI.char_unreserved?/1)

  defp tab_label("submitted"), do: "Awaiting decision"
  defp tab_label("approved"), do: "Approved"
  defp tab_label("reimbursed"), do: "Reimbursed"
  defp tab_label("rejected"), do: "Rejected"
  defp tab_label("batches"), do: "Hand-off batches"

  defp pending_text({:approve, request, attrs}),
    do:
      {"Claim #{request.id} of #{request.employee_name} will be approved for #{approving(request, attrs)} #{request.currency}.",
       "The decision is recorded with your name and cannot be undone.", "Approve", "Approving…"}

  defp pending_text({:reject, request, _attrs}),
    do:
      {"Claim #{request.id} of #{request.employee_name} will be rejected.",
       "The employee sees your reason. This cannot be undone.", "Reject", "Rejecting…"}

  defp pending_text({:reimburse, request, _attrs}),
    do:
      {"Claim #{request.id} will be marked reimbursed for #{money(request.approved_amount)} #{request.currency}.",
       "Record this only after payment. This cannot be undone.", "Mark reimbursed", "Saving…"}

  defp pending_text({:handoff, currency, _attrs}),
    do:
      {"All approved #{currency} claims not yet handed off will join one batch.",
       "The batch is a permanent record of who handed them off and when.", "Create batch",
       "Creating…"}

  defp pending_text({:reimburse_batch, batch, _attrs}),
    do:
      {"Approved claims in batch #{batch.id} will be marked reimbursed.",
       "Record this only after payment. This cannot be undone.", "Mark reimbursed", "Saving…"}

  defp approving(request, attrs) do
    case Map.get(attrs, "approved_amount", "") do
      "" -> money(request.amount)
      amount -> amount
    end
  end

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people">
      <.page id="people-claim-operations" variant={:list}>
        <.header>
          Claim operations
          <:subtitle>Decide claims, record reimbursement, and hand approved claims off.</:subtitle>
        </.header>

        <div :if={@company == nil} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state id="claim-operations-empty" title="No company is available for claim operations." />
        </div>

        <div :if={@company} class="mt-5 space-y-5">
          <form id="claim-operations-company" phx-change="select_company">
            <label for="claim-operations-company-select" class="block text-sm font-medium text-ink-strong">
              Company
            </label>
            <select id="claim-operations-company-select" name="company_id" class={["mt-2.5 w-full", @input]}>
              <option :for={company <- @companies} value={company.id} selected={company.id == @company.id}>
                {company.name}
              </option>
            </select>
          </form>

          <.tabs id="claim-operations-tabs" aria-label="Claim queues">
            <:tab
              :for={tab <- ~w(submitted approved reimbursed rejected batches)}
              id={"claim-tab-#{tab}"}
              patch={~p"/people/claims/operations?company_id=#{@company.id}&tab=#{tab}"}
              current={@tab == tab}
            >
              {tab_label(tab)}
            </:tab>
          </.tabs>

          <.card :if={@tab != "batches"} inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-queue-heading">
            <.section_heading id="claim-queue-heading" title={tab_label(@tab)} />

            <div :if={@tab == "approved" and @waiting != [] and @can_reimburse} id="claim-handoff-waiting" class="mt-3 space-y-1 text-sm">
              <p :for={{currency, count, total} <- @waiting} class="flex flex-wrap items-center gap-3">
                <span>{count} approved in {currency}, {money(total)} in total, not handed off.</span>
                <button
                  type="button"
                  phx-click="handoff"
                  phx-value-currency={currency}
                  class="text-link hover:underline"
                >
                  Create {currency} hand-off batch
                </button>
              </p>
            </div>

            <p :if={@rows == []} id="claim-queue-empty" class="mt-2 text-sm text-ink-muted">
              No claims are {String.downcase(tab_label(@tab))}.
            </p>

            <div :if={@rows != []} class="mt-3 overflow-x-auto border border-line">
              <table id="claim-queue-table" class="w-full text-left text-sm">
                <thead class="bg-surface-sunken text-xs text-ink-muted">
                  <tr>
                    <th class="px-2 py-1.5">Employee</th>
                    <th class="px-2 py-1.5">Claim</th>
                    <th class="px-2 py-1.5">Date</th>
                    <th class="px-2 py-1.5 text-right">Claimed</th>
                    <th :if={@tab != "submitted"} class="px-2 py-1.5 text-right">Approved</th>
                    <th class="px-2 py-1.5">Receipt</th>
                    <th :if={@tab in ["approved", "reimbursed"]} class="px-2 py-1.5">Batch</th>
                    <th :if={@tab in ["rejected"]} class="px-2 py-1.5">Reason</th>
                    <th :if={@tab == "reimbursed"} class="px-2 py-1.5">Paid</th>
                    <th class="px-2 py-1.5"><span class="sr-only">Actions</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @rows} id={"claim-row-#{row.id}"} class="border-t border-line align-top">
                    <td class="px-2 py-0.5">
                      {row.employee_name || "—"}
                      <span class="text-ink-muted">{row.employee_number}</span>
                    </td>
                    <td class="px-2 py-0.5">
                      {row.claim_type_name}
                      <span class="text-ink-muted">· {row.category_name}</span>
                      <span :if={row.description} class="block text-xs text-ink-muted">{row.description}</span>
                      <span :if={row.duplicate_confirmed} class="block text-xs text-warning-ink">
                        Submitter confirmed a similar claim.
                      </span>
                    </td>
                    <td class="px-2 py-0.5 tabular-nums">{Date.to_iso8601(row.incurred_on)}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">{money(row.amount)} {row.currency}</td>
                    <td :if={@tab != "submitted"} class="px-2 py-0.5 text-right tabular-nums">
                      {money(row.approved_amount)}
                    </td>
                    <td class="px-2 py-0.5">{row.receipt_number || "—"}</td>
                    <td :if={@tab in ["approved", "reimbursed"]} class="px-2 py-0.5">
                      {row.handoff_batch_id || "—"}
                    </td>
                    <td :if={@tab == "rejected"} class="px-2 py-0.5">{row.decision_reason}</td>
                    <td :if={@tab == "reimbursed"} class="px-2 py-0.5">
                      {moment(row.reimbursed_at)}
                      <span :if={row.payment_reference} class="text-ink-muted">· {row.payment_reference}</span>
                    </td>
                    <td class="px-2 py-0.5">
                      <form :if={@tab == "submitted"} id={"decide-#{row.id}"} phx-submit="decide" class="flex flex-wrap gap-1">
                        <input type="hidden" name="request_id" value={row.id} />
                        <input
                          name="approved_amount"
                          inputmode="decimal"
                          aria-label="Approved amount"
                          placeholder={"Approve #{money(row.amount)}"}
                          class={["w-28", @input]}
                        />
                        <input
                          name="decision_reason"
                          aria-label="Reason"
                          placeholder="Reason"
                          maxlength="500"
                          class={["w-40", @input]}
                        />
                        <button type="submit" name="decision" value="approve" class="text-link hover:underline">
                          Approve
                        </button>
                        <button type="submit" name="decision" value="reject" class="text-link hover:underline">
                          Reject
                        </button>
                      </form>
                      <form
                        :if={@tab == "approved" and @can_reimburse}
                        id={"reimburse-#{row.id}"}
                        phx-submit="reimburse"
                        class="flex flex-wrap gap-1"
                      >
                        <input type="hidden" name="request_id" value={row.id} />
                        <input
                          name="payment_reference"
                          aria-label="Payment reference"
                          placeholder="Payment reference"
                          maxlength="100"
                          class={["w-40", @input]}
                        />
                        <button type="submit" class="text-link hover:underline">Mark reimbursed</button>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={length(@rows) >= 500} class="mt-2 text-xs text-ink-muted">
              Showing the first 500 claims.
            </p>
          </.card>

          <.card :if={@tab == "batches"} inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-batches-heading">
            <.section_heading id="claim-batches-heading" title="Hand-off batches" />
            <p class="mt-1 text-xs text-ink-muted">
              A batch groups approved claims of one currency for finance or payroll. Export it as a CSV, then mark it reimbursed once paid.
            </p>
            <p :if={not @can_reimburse} id="claim-batches-forbidden" class="mt-2 text-sm text-ink-muted">
              Hand-off batches need the reimbursement permission.
            </p>
            <p :if={@can_reimburse and @batches == []} id="claim-batches-empty" class="mt-2 text-sm text-ink-muted">
              No hand-off batches have been created for this company.
            </p>
            <ul :if={@can_reimburse and @batches != []} id="claim-batches-list" class="mt-3 divide-y divide-line text-sm">
              <li :for={batch <- @batches} id={"claim-batch-#{batch.id}"} class="flex flex-wrap items-center gap-3 py-2">
                <span class="font-medium">Batch {batch.id}</span>
                <span class="text-ink-muted">
                  {batch.request_count} claims · {money(batch.total_amount)} {batch.currency} · {moment(batch.created_at)}
                </span>
                <button type="button" phx-click="export" phx-value-id={batch.id} class="text-link hover:underline">
                  Prepare CSV
                </button>
                <a
                  :if={@export && @export.batch_id == batch.id}
                  id={"claim-batch-download-#{batch.id}"}
                  href={data_link(@export)}
                  download={@export.filename}
                  class="text-link hover:underline"
                >
                  Download {@export.filename}
                </a>
                <form id={"reimburse-batch-#{batch.id}"} phx-submit="reimburse_batch" class="flex gap-1">
                  <input type="hidden" name="batch_id" value={batch.id} />
                  <input
                    name="payment_reference"
                    aria-label="Payment reference"
                    placeholder="Payment reference"
                    maxlength="100"
                    class={["w-40", @input]}
                  />
                  <button type="submit" class="text-link hover:underline">Mark reimbursed</button>
                </form>
              </li>
            </ul>
          </.card>
        </div>

        <.confirm_dialog
          :if={@pending}
          id="claim-operations-confirm"
          consequence={elem(pending_text(@pending), 0)}
          detail={elem(pending_text(@pending), 1)}
          confirm={elem(pending_text(@pending), 2)}
          working={elem(pending_text(@pending), 3)}
          on_confirm={JS.push("confirm")}
          on_cancel={JS.push("cancel")}
        />
      </.page>
    </Layouts.app>
    """
  end
end
