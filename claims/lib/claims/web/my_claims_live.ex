defmodule Bilimbi.People.Claims.Web.MyClaimsLive do
  @moduledoc """
  Self-service claims for the working employee linked to the signed-in actor.

  The signed-in actor's company is the explicit company axis. A login actor
  that is not linked to a working employee there sees an unavailable state and
  cannot submit.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Claims

  @capability "people.claims.submit"

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_scope.actor
    company_id = actor.company_id

    employee =
      with {:ok, _company} <- Company.authorize_company_target(actor, company_id, @capability),
           {:ok, employee} <- Claims.self_service_employee(actor.scope, company_id, actor.id) do
        employee
      else
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:page_title, "My claims")
     |> assign(:company_id, company_id)
     |> assign(:employee, employee)
     |> assign(:possible_duplicate?, false)
     |> assign(:claim, %{})
     |> load()}
  end

  # Submitting and withdrawing act only on the signed-in actor's own linked
  # employee; the route capability is the self-service grant.
  @impl true
  def handle_event("submit_claim", %{"claim" => attrs}, socket) do
    if socket.assigns.employee do
      case Claims.submit_request(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.employee.id,
             actor_id(socket),
             attrs
           ) do
        {:ok, _request} ->
          {:noreply,
           socket
           |> assign(:possible_duplicate?, false)
           |> assign(:claim, %{})
           |> load()
           |> clear_flash(:error)
           |> put_flash(:info, "Claim submitted.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:possible_duplicate?, reason == :possible_duplicate)
           |> assign(:claim, attrs)
           |> clear_flash(:info)
           |> put_flash(:error, refusal(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("withdraw_claim", %{"id" => raw_id}, socket) do
    with %{id: employee_id} <- socket.assigns.employee,
         {id, ""} <- Integer.parse(raw_id),
         {:ok, _request} <-
           Claims.withdraw_request(
             scope(socket),
             socket.assigns.company_id,
             employee_id,
             id,
             actor_id(socket)
           ) do
      {:noreply,
       socket
       |> load()
       |> clear_flash(:error)
       |> put_flash(:info, "Claim withdrawn.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "This claim cannot be withdrawn.")}
    end
  end

  @doc "Employee-facing text for a submission refusal."
  def refusal(:employee_unavailable), do: "You are not a working employee of this company."
  def refusal(:claim_type_unavailable), do: "Choose a claim type that is open for claims."
  def refusal(:claim_type_not_assigned), do: "This claim type is not assigned to you."
  def refusal(:future_incurred_on), do: "The expense date cannot be in the future."
  def refusal(:no_effective_policy), do: "No claim policy covers this type on the expense date."
  def refusal(:currency_not_allowed), do: "Use the currency shown for this claim type."
  def refusal(:receipt_required), do: "This claim needs a receipt number."
  def refusal(:per_claim_limit_exceeded), do: "The amount is above the per-claim limit."
  def refusal(:monthly_limit_exceeded), do: "The amount would exceed this month's limit."
  def refusal(:yearly_limit_exceeded), do: "The amount would exceed this year's limit."
  def refusal(:duplicate_receipt), do: "This receipt number is already on one of your claims."

  def refusal(:possible_duplicate),
    do:
      "You already claimed this type, date, and amount. Confirm it is a separate expense to submit."

  def refusal(_reason), do: "Check the claim details."

  defp load(%{assigns: %{employee: nil}} = socket),
    do: socket |> assign(:open_types, []) |> assign(:requests, []) |> assign(:type_names, %{})

  defp load(socket) do
    scope = scope(socket)
    company_id = socket.assigns.company_id

    with {:ok, open_types} <-
           Claims.open_claim_types(scope, company_id, nil, employee_id: socket.assigns.employee.id),
         {:ok, all_types} <- Claims.claim_types(scope, company_id),
         {:ok, requests} <-
           Claims.employee_requests(scope, company_id, socket.assigns.employee.id) do
      socket
      |> assign(:open_types, open_types)
      |> assign(:requests, requests)
      |> assign(:type_names, Map.new(all_types, &{&1.id, &1.name}))
    else
      _ -> socket |> assign(:employee, nil) |> load()
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp actor_id(socket), do: socket.assigns.current_scope.actor.id

  defp limits(policy) do
    [
      {"per claim", policy.per_claim_limit},
      {"per month", policy.monthly_limit},
      {"per year", policy.yearly_limit}
    ]
    |> Enum.reject(fn {_label, limit} -> is_nil(limit) end)
    |> Enum.map_join(" · ", fn {label, limit} -> "#{Decimal.to_string(limit)} #{label}" end)
  end

  defp decision(%{status: "approved"} = request), do: approved_text(request)

  defp decision(%{status: "reimbursed"} = request),
    do: "#{approved_text(request)}, paid #{Date.to_iso8601(NaiveDateTime.to_date(request.reimbursed_at))}"

  defp decision(%{status: "rejected", decision_reason: reason}), do: reason
  defp decision(_request), do: "—"

  defp approved_text(request) do
    text = "Approved #{Decimal.to_string(request.approved_amount)} #{request.currency}"
    if request.decision_reason, do: "#{text}: #{request.decision_reason}", else: text
  end

  defp receipt_rule(%{receipt_requirement: "always"}), do: "Receipt required"
  defp receipt_rule(%{receipt_requirement: "never"}), do: "No receipt needed"

  defp receipt_rule(%{policy: %{receipt_threshold: threshold}}),
    do: "Receipt required above #{Decimal.to_string(threshold)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people">
      <.page id="people-my-claims" variant={:list}>
        <.header>
          My claims
          <:subtitle :if={@employee}>{@employee.display_name} · {@employee.employee_number}</:subtitle>
        </.header>

        <div :if={is_nil(@employee)} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="my-claims-unavailable"
            title="Your account is not linked to a working employee in this company."
          />
        </div>

        <div :if={@employee} class="mt-5 space-y-5">
          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="new-claim-heading">
            <.section_heading id="new-claim-heading" title="New claim" />
            <p :if={@open_types == []} id="my-claims-no-types" class="mt-2 text-sm text-ink-muted">
              No claim types are open for claims yet.
            </p>
            <ul :if={@open_types != []} id="my-claims-open-types" class="mt-2 space-y-1 text-sm">
              <li :for={type <- @open_types}>
                <span class="font-medium text-ink">{type.name}</span>
                <span class="text-ink-muted">
                  · {type.category_name} · {type.policy.currency}
                  <span :if={limits(type.policy) != ""}>· {limits(type.policy)}</span>
                  · {receipt_rule(type)}
                </span>
              </li>
            </ul>
            <form
              :if={@open_types != []}
              id="my-claims-form"
              phx-submit="submit_claim"
              class="mt-4 grid gap-2 sm:grid-cols-2"
            >
              <select
                name="claim[claim_type_id]"
                aria-label="Claim type"
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              >
                <option
                  :for={type <- @open_types}
                  value={type.id}
                  selected={@claim["claim_type_id"] == to_string(type.id)}
                >
                  {type.name}
                </option>
              </select>
              <input
                type="date"
                name="claim[incurred_on]"
                value={@claim["incurred_on"]}
                aria-label="Expense date"
                required
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              />
              <input
                name="claim[amount]"
                value={@claim["amount"]}
                inputmode="decimal"
                aria-label="Amount"
                placeholder="Amount"
                required
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              />
              <select
                name="claim[currency]"
                aria-label="Currency"
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              >
                <option
                  :for={currency <- @open_types |> Enum.map(& &1.policy.currency) |> Enum.uniq()}
                  value={currency}
                  selected={@claim["currency"] == currency}
                >
                  {currency}
                </option>
              </select>
              <input
                name="claim[receipt_number]"
                value={@claim["receipt_number"]}
                aria-label="Receipt number"
                placeholder="Receipt number"
                maxlength="100"
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              />
              <input
                name="claim[description]"
                value={@claim["description"]}
                aria-label="Description"
                placeholder="Description"
                maxlength="500"
                class="rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
              />
              <label :if={@possible_duplicate?} class="flex items-center gap-2 text-sm text-ink sm:col-span-2">
                <input type="checkbox" name="claim[confirm_duplicate]" value="true" />
                This is a separate expense, not a repeat of an earlier claim.
              </label>
              <div class="sm:col-span-2">
                <.button id="my-claims-submit" type="submit" variant="primary">Submit claim</.button>
              </div>
            </form>
          </.card>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claims-heading">
            <.section_heading id="claims-heading" title="Submitted claims" />
            <p :if={@requests == []} id="my-claims-empty" class="mt-2 text-sm text-ink-muted">
              You have not submitted any claims.
            </p>
            <div :if={@requests != []} class="mt-3 overflow-x-auto border border-line">
              <table id="my-claims-table" class="w-full text-left text-sm">
                <thead class="bg-surface-sunken text-xs text-ink-muted">
                  <tr>
                    <th class="px-2 py-1.5">Type</th>
                    <th class="px-2 py-1.5">Date</th>
                    <th class="px-2 py-1.5 text-right">Amount</th>
                    <th class="px-2 py-1.5">Receipt</th>
                    <th class="px-2 py-1.5">Status</th>
                    <th class="px-2 py-1.5">Decision</th>
                    <th class="px-2 py-1.5"><span class="sr-only">Actions</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={request <- @requests} id={"claim-#{request.id}"} class="border-t border-line">
                    <td class="px-2 py-0.5">{Map.get(@type_names, request.claim_type_id, "—")}</td>
                    <td class="px-2 py-0.5 tabular-nums">{Date.to_iso8601(request.incurred_on)}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">
                      {Decimal.to_string(request.amount)} {request.currency}
                    </td>
                    <td class="px-2 py-0.5">{request.receipt_number || "—"}</td>
                    <td class="px-2 py-0.5">{String.capitalize(request.status)}</td>
                    <td class="px-2 py-0.5">{decision(request)}</td>
                    <td class="px-2 py-0.5">
                      <button
                        :if={request.status == "submitted"}
                        type="button"
                        phx-click="withdraw_claim"
                        phx-value-id={request.id}
                        class="text-link hover:underline"
                      >
                        Withdraw
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
