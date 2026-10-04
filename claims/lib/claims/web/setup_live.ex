defmodule Bilimbi.People.Claims.Web.SetupLive do
  @moduledoc """
  Operator setup for one company's claim currencies, catalog, and policies.

  The company list comes from `Company.list_selectable_companies/2` under the
  route capability, so an operator only reaches companies they may manage.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Claims
  alias Bilimbi.People.Claims.ClaimType

  @capability "people.claims.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.scope, @capability) do
        {:ok, companies} -> companies
        {:error, :unauthorized} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Claim policies")
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_company(socket, Map.get(params, "company_id"))}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => company_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/people/claims/setup?company_id=#{company_id}")}
  end

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_currencies", %{"currencies" => raw}, socket) do
    codes = raw |> String.split([",", " ", "\n"], trim: true)

    socket
    |> outcome(
      Claims.put_currencies(scope(socket), company_id(socket), codes),
      "Claim currencies saved.",
      "Enter up to 20 three-letter currency codes."
    )
  end

  def handle_event("create_category", %{"category" => attrs}, socket) do
    socket
    |> outcome(
      Claims.create_category(scope(socket), company_id(socket), attrs),
      "Category added.",
      "Check the category fields and unique code."
    )
  end

  def handle_event("toggle_category", %{"id" => raw_id, "active" => active}, socket) do
    socket
    |> outcome(
      Claims.set_category_active(
        scope(socket),
        company_id(socket),
        positive_id(raw_id),
        active == "true"
      ),
      "Category updated.",
      "Category unavailable."
    )
  end

  def handle_event("create_claim_type", %{"claim_type" => attrs}, socket) do
    socket
    |> outcome(
      Claims.create_claim_type(scope(socket), company_id(socket), attrs),
      "Claim type added.",
      "Choose a category and check the claim type fields and unique code."
    )
  end

  def handle_event("toggle_claim_type", %{"id" => raw_id, "active" => active}, socket) do
    socket
    |> outcome(
      Claims.set_claim_type_active(
        scope(socket),
        company_id(socket),
        positive_id(raw_id),
        active == "true"
      ),
      "Claim type updated.",
      "Claim type unavailable."
    )
  end

  def handle_event("create_assignment", %{"assignment" => attrs}, socket) do
    socket
    |> outcome(
      Claims.create_assignment(scope(socket), company_id(socket), attrs),
      "Assignment added.",
      "Check the assignment fields, its dates, and unique code."
    )
  end

  def handle_event("end_assignment", %{"assignment_id" => raw_id, "effective_to" => date}, socket) do
    socket
    |> outcome(
      Claims.end_assignment(scope(socket), company_id(socket), positive_id(raw_id), date),
      "Assignment end date saved.",
      "Choose an end date on or after the start date."
    )
  end

  def handle_event("save_assignment_members", %{"assignment_id" => raw_id} = params, socket) do
    scope = scope(socket)
    company_id = company_id(socket)
    id = positive_id(raw_id)

    case Claims.set_assignment_members(
           scope,
           company_id,
           id,
           Map.get(params, "claim_type_ids", []),
           Map.get(params, "employee_ids", [])
         ) do
      {:ok, _members} ->
        {:noreply,
         socket
         |> load()
         |> clear_flash(:error)
         |> put_flash(:info, "Assignment members saved.")}

      {:error, :unauthorized} ->
        {:noreply, socket |> load() |> put_flash(:error, forbidden())}

      _ ->
        {:noreply, put_flash(socket, :error, "Choose claim types and employees of this company.")}
    end
  end

  def handle_event("create_policy", %{"policy" => attrs}, socket) do
    case Claims.create_policy(scope(socket), company_id(socket), attrs) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> load()
         |> clear_flash(:error)
         |> put_flash(:info, "Policy added.")}

      {:error, :unauthorized} ->
        {:noreply, socket |> load() |> put_flash(:error, forbidden())}

      {:error, :overlapping_policy} ->
        {:noreply,
         put_flash(socket, :error, "This period overlaps another policy for the claim type.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Check the dates, an allowed currency, positive limits, and any receipt threshold."
         )}
    end
  end

  def handle_event("end_policy", %{"policy_id" => raw_id, "effective_to" => effective_to}, socket) do
    case Claims.end_policy(scope(socket), company_id(socket), positive_id(raw_id), effective_to) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> load()
         |> clear_flash(:error)
         |> put_flash(:info, "Policy end date saved.")}

      {:error, :unauthorized} ->
        {:noreply, socket |> load() |> put_flash(:error, forbidden())}

      {:error, :requests_after_end} ->
        {:noreply,
         put_flash(socket, :error, "Claims under this policy were incurred after that date.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Choose an end date on or after the start date.")}
    end
  end

  defp outcome(socket, {:ok, _value}, success, _failure),
    do:
      {:noreply,
       socket
       |> load()
       |> clear_flash(:error)
       |> put_flash(:info, success)}

  defp outcome(socket, {:error, :unauthorized}, _success, _failure),
    do: {:noreply, socket |> load() |> put_flash(:error, forbidden())}

  defp outcome(socket, {:error, _reason}, _success, failure),
    do: {:noreply, put_flash(socket, :error, failure)}

  defp forbidden, do: "You no longer have permission to change this company's claim policies."

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do: socket |> assign(:company, nil) |> clear()

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))
    socket |> assign(:company, company) |> load()
  end

  defp load(socket) do
    scope = scope(socket)
    company_id = company_id(socket)

    with {:ok, currencies} <- Claims.currencies(scope, company_id),
         {:ok, categories} <- Claims.categories(scope, company_id),
         {:ok, claim_types} <- Claims.claim_types(scope, company_id),
         {:ok, policies} <- Claims.policies(scope, company_id),
         {:ok, assignments} <- Claims.assignments(scope, company_id),
         {:ok, employees} <- Claims.assignable_employees(scope, company_id) do
      assign(socket,
        currencies: currencies,
        categories: categories,
        claim_types: claim_types,
        policies: policies,
        assignments: assignments,
        employees: employees
      )
    else
      _ -> socket |> assign(:company, nil) |> clear()
    end
  end

  defp clear(socket),
    do:
      assign(socket,
        currencies: [],
        categories: [],
        claim_types: [],
        policies: [],
        assignments: [],
        employees: []
      )

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.company.id

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp name_of(records, id), do: Enum.find_value(records, "—", &(&1.id == id && &1.name))

  defp amount(nil), do: "—"
  defp amount(value), do: Decimal.to_string(value)

  defp receipt_label("always"), do: "Always"
  defp receipt_label("above_threshold"), do: "Above threshold"
  defp receipt_label("never"), do: "Never"

  defp eligibility_label("all_employees"), do: "All working employees"
  defp eligibility_label("assigned_only"), do: "Assigned employees only"

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people">
      <.page id="people-claim-setup" variant={:form}>
        <.header>
          Claim policies
          <:subtitle>Currencies, claim types, assignments, and effective-dated limits for one company.</:subtitle>
        </.header>

        <div :if={@company == nil} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state id="claim-setup-empty" title="No company is available for claim setup." />
        </div>

        <div :if={@company} class="mt-5 space-y-5">
          <form id="claim-setup-company" phx-change="select_company">
            <label for="claim-setup-company-select" class="block text-sm font-medium text-ink-strong">
              Company
            </label>
            <select id="claim-setup-company-select" name="company_id" class={["mt-2.5 w-full", @input]}>
              <option :for={company <- @companies} value={company.id} selected={company.id == @company.id}>
                {company.name}
              </option>
            </select>
          </form>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-currencies-heading">
            <.section_heading id="claim-currencies-heading" title="Claim currencies" />
            <p class="mt-1 text-xs text-ink-muted">
              Policies and claims use only these codes. With none, no claim can be submitted.
            </p>
            <form id="claim-currencies-form" phx-submit="save_currencies" class="mt-3 flex flex-wrap gap-2">
              <input
                name="currencies"
                value={Enum.join(@currencies, ", ")}
                aria-label="Currency codes"
                placeholder="Three-letter codes, comma separated"
                class={["min-w-64 flex-1", @input]}
              />
              <.button type="submit" variant="primary">Save currencies</.button>
            </form>
          </.card>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-categories-heading">
            <.section_heading id="claim-categories-heading" title="Categories" />
            <p :if={@categories == []} id="claim-categories-empty" class="mt-2 text-sm text-ink-muted">
              No claim categories have been added for this company.
            </p>
            <ul :if={@categories != []} class="mt-3 divide-y divide-line text-sm">
              <li :for={category <- @categories} class="flex items-center gap-3 py-1.5">
                <span class="font-medium">{category.name}</span>
                <span class="text-ink-muted">{category.code}</span>
                <span class="text-ink-muted">{if category.active, do: "Active", else: "Inactive"}</span>
                <button
                  type="button"
                  phx-click="toggle_category"
                  phx-value-id={category.id}
                  phx-value-active={to_string(!category.active)}
                  class="text-link hover:underline"
                >
                  {if category.active, do: "Deactivate", else: "Activate"}
                </button>
              </li>
            </ul>
            <form id="claim-category-form" phx-submit="create_category" class="mt-3 flex flex-wrap gap-2">
              <input name="category[code]" aria-label="Category code" placeholder="Code" required maxlength="60" class={@input} />
              <input name="category[name]" aria-label="Category name" placeholder="Name" required maxlength="120" class={@input} />
              <.button type="submit">Add category</.button>
            </form>
          </.card>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-types-heading">
            <.section_heading id="claim-types-heading" title="Claim types" />
            <p :if={@claim_types == []} id="claim-types-empty" class="mt-2 text-sm text-ink-muted">
              No claim types have been added for this company.
            </p>
            <ul :if={@claim_types != []} class="mt-3 divide-y divide-line text-sm">
              <li :for={claim_type <- @claim_types} class="flex flex-wrap items-center gap-3 py-1.5">
                <span class="font-medium">{claim_type.name}</span>
                <span class="text-ink-muted">{claim_type.code}</span>
                <span class="text-ink-muted">{name_of(@categories, claim_type.category_id)}</span>
                <span class="text-ink-muted">Receipt: {receipt_label(claim_type.receipt_requirement)}</span>
                <span class="text-ink-muted">{eligibility_label(claim_type.eligibility)}</span>
                <span class="text-ink-muted">{if claim_type.active, do: "Active", else: "Inactive"}</span>
                <button
                  type="button"
                  phx-click="toggle_claim_type"
                  phx-value-id={claim_type.id}
                  phx-value-active={to_string(!claim_type.active)}
                  class="text-link hover:underline"
                >
                  {if claim_type.active, do: "Deactivate", else: "Activate"}
                </button>
              </li>
            </ul>
            <p :if={@categories == []} class="mt-3 text-xs text-ink-muted">Add a category before adding claim types.</p>
            <form
              :if={@categories != []}
              id="claim-type-form"
              phx-submit="create_claim_type"
              class="mt-3 flex flex-wrap gap-2"
            >
              <select name="claim_type[category_id]" aria-label="Claim category" class={@input}>
                <option :for={category <- @categories} value={category.id}>{category.name}</option>
              </select>
              <input name="claim_type[code]" aria-label="Claim type code" placeholder="Code" required maxlength="60" class={@input} />
              <input name="claim_type[name]" aria-label="Claim type name" placeholder="Name" required maxlength="120" class={@input} />
              <select name="claim_type[receipt_requirement]" aria-label="Receipt requirement" class={@input}>
                <option :for={requirement <- ClaimType.receipt_requirements()} value={requirement}>
                  Receipt: {receipt_label(requirement)}
                </option>
              </select>
              <select name="claim_type[eligibility]" aria-label="Who may claim" class={@input}>
                <option :for={eligibility <- ClaimType.eligibilities()} value={eligibility}>
                  {eligibility_label(eligibility)}
                </option>
              </select>
              <.button type="submit">Add claim type</.button>
            </form>
          </.card>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-assignments-heading">
            <.section_heading id="claim-assignments-heading" title="Assignments" />
            <p class="mt-1 text-xs text-ink-muted">
              An assignment opens assigned-only claim types for the employees it covers while it is in effect.
            </p>
            <p :if={@assignments == []} id="claim-assignments-empty" class="mt-2 text-sm text-ink-muted">
              No claim assignments have been added for this company.
            </p>
            <div
              :for={assignment <- @assignments}
              id={"claim-assignment-#{assignment.id}"}
              class="mt-3 rounded-md border border-line p-3 text-sm"
            >
              <p class="flex flex-wrap items-center gap-3">
                <span class="font-medium">{assignment.name}</span>
                <span class="text-ink-muted">{assignment.code}</span>
                <span class="tabular-nums text-ink-muted">
                  {Date.to_iso8601(assignment.effective_from)} to {(assignment.effective_to && Date.to_iso8601(assignment.effective_to)) || "open"}
                </span>
              </p>
              <form
                :if={is_nil(assignment.effective_to)}
                phx-submit="end_assignment"
                class="mt-2 flex gap-1"
              >
                <input type="hidden" name="assignment_id" value={assignment.id} />
                <input type="date" name="effective_to" aria-label="Assignment end date" required class={@input} />
                <button type="submit" class="text-link hover:underline">End</button>
              </form>
              <form
                id={"claim-assignment-members-#{assignment.id}"}
                phx-submit="save_assignment_members"
                class="mt-2 grid gap-3 sm:grid-cols-2"
              >
                <input type="hidden" name="assignment_id" value={assignment.id} />
                <fieldset>
                  <legend class="text-xs font-medium text-ink-muted">Claim types</legend>
                  <p :if={@claim_types == []} class="text-xs text-ink-muted">No claim types yet.</p>
                  <label :for={claim_type <- @claim_types} class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      name="claim_type_ids[]"
                      value={claim_type.id}
                      checked={claim_type.id in assignment.claim_type_ids}
                    />
                    {claim_type.name}
                  </label>
                </fieldset>
                <fieldset class="max-h-56 overflow-y-auto">
                  <legend class="text-xs font-medium text-ink-muted">Employees</legend>
                  <p :if={@employees == []} class="text-xs text-ink-muted">No employees in this company.</p>
                  <label :for={employee <- @employees} class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      name="employee_ids[]"
                      value={employee.id}
                      checked={employee.id in assignment.employee_ids}
                    />
                    {employee.name} <span class="text-ink-muted">{employee.employee_number}</span>
                  </label>
                </fieldset>
                <div class="sm:col-span-2">
                  <.button type="submit">Save members</.button>
                </div>
              </form>
            </div>
            <form id="claim-assignment-form" phx-submit="create_assignment" class="mt-3 flex flex-wrap gap-2">
              <input name="assignment[code]" aria-label="Assignment code" placeholder="Code" required maxlength="60" class={@input} />
              <input name="assignment[name]" aria-label="Assignment name" placeholder="Name" required maxlength="120" class={@input} />
              <input type="date" name="assignment[effective_from]" aria-label="Assignment effective from" required class={@input} />
              <input type="date" name="assignment[effective_to]" aria-label="Assignment effective to" class={@input} />
              <.button type="submit">Add assignment</.button>
            </form>
          </.card>

          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="claim-policies-heading">
            <.section_heading id="claim-policies-heading" title="Policies" />
            <p class="mt-1 text-xs text-ink-muted">
              A claim is checked against the policy in effect on its expense date. Periods of one claim type never overlap.
            </p>
            <p :if={@policies == []} id="claim-policies-empty" class="mt-2 text-sm text-ink-muted">
              No claim policies have been added for this company.
            </p>
            <div :if={@policies != []} class="mt-3 overflow-x-auto border border-line">
              <table id="claim-policies-table" class="w-full text-left text-sm">
                <thead class="bg-surface-sunken text-xs text-ink-muted">
                  <tr>
                    <th class="px-2 py-1.5">Claim type</th>
                    <th class="px-2 py-1.5">From</th>
                    <th class="px-2 py-1.5">To</th>
                    <th class="px-2 py-1.5">Currency</th>
                    <th class="px-2 py-1.5 text-right">Per claim</th>
                    <th class="px-2 py-1.5 text-right">Per month</th>
                    <th class="px-2 py-1.5 text-right">Per year</th>
                    <th class="px-2 py-1.5 text-right">Receipt above</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={policy <- @policies} id={"claim-policy-#{policy.id}"} class="border-t border-line">
                    <td class="px-2 py-0.5">{name_of(@claim_types, policy.claim_type_id)}</td>
                    <td class="px-2 py-0.5 tabular-nums">{Date.to_iso8601(policy.effective_from)}</td>
                    <td class="px-2 py-0.5 tabular-nums">
                      <span :if={policy.effective_to}>{Date.to_iso8601(policy.effective_to)}</span>
                      <form :if={is_nil(policy.effective_to)} phx-submit="end_policy" class="flex gap-1">
                        <input type="hidden" name="policy_id" value={policy.id} />
                        <input type="date" name="effective_to" aria-label="Policy end date" required class={@input} />
                        <button type="submit" class="text-link hover:underline">End</button>
                      </form>
                    </td>
                    <td class="px-2 py-0.5">{policy.currency}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">{amount(policy.per_claim_limit)}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">{amount(policy.monthly_limit)}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">{amount(policy.yearly_limit)}</td>
                    <td class="px-2 py-0.5 text-right tabular-nums">{amount(policy.receipt_threshold)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@claim_types == [] or @currencies == []} class="mt-3 text-xs text-ink-muted">
              Add a claim type and a claim currency before adding policies.
            </p>
            <form
              :if={@claim_types != [] and @currencies != []}
              id="claim-policy-form"
              phx-submit="create_policy"
              class="mt-3 grid gap-2 sm:grid-cols-4"
            >
              <select name="policy[claim_type_id]" aria-label="Policy claim type" class={@input}>
                <option :for={claim_type <- @claim_types} value={claim_type.id}>{claim_type.name}</option>
              </select>
              <input type="date" name="policy[effective_from]" aria-label="Effective from" required class={@input} />
              <input type="date" name="policy[effective_to]" aria-label="Effective to" class={@input} />
              <select name="policy[currency]" aria-label="Policy currency" class={@input}>
                <option :for={currency <- @currencies} value={currency}>{currency}</option>
              </select>
              <input name="policy[per_claim_limit]" inputmode="decimal" aria-label="Per-claim limit" placeholder="Per-claim limit" class={@input} />
              <input name="policy[monthly_limit]" inputmode="decimal" aria-label="Monthly limit" placeholder="Monthly limit" class={@input} />
              <input name="policy[yearly_limit]" inputmode="decimal" aria-label="Yearly limit" placeholder="Yearly limit" class={@input} />
              <input name="policy[receipt_threshold]" inputmode="decimal" aria-label="Receipt threshold" placeholder="Receipt above (threshold types)" class={@input} />
              <div class="sm:col-span-4">
                <.button type="submit" variant="primary">Add policy</.button>
              </div>
            </form>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
