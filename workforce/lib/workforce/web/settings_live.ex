defmodule Bilimbi.People.Workforce.Web.SettingsLive do
  @moduledoc """
  Per-company operator settings for the People workforce seam.

  The company list comes from `Authorization.selectable_companies/2` under the
  route capability, so an operator only reaches companies they may manage.

  The employment records section shows where the company's employment facts
  come from, lists the legacy Core Employee rows People could not claim and
  why, and lets an operator holding `people.workforce.employment.manage`
  re-run the claim that the production seed ran. The `can_*?` assigns only
  decide what renders; the facade authorizes each read and the claim.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @capability "people.workforce.settings.manage"
  @employment_manage_capability "people.workforce.employment.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Authorization.selectable_companies(socket.assigns.current_scope.scope, @capability) do
        {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
        {:error, :unauthorized} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Workforce Settings")
     |> assign(:active_nav, nil)
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_company(socket, Map.get(params, "company_id"))}
  end

  @impl true
  def handle_event(
        "reconcile_employments",
        _params,
        %{assigns: %{can_manage_employment?: false}} = socket
      ),
      do: {:noreply, put_flash(socket, :error, "You cannot claim employment records here.")}

  def handle_event("select_company", %{"company_id" => company_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/people/workforce/settings?company_id=#{company_id}")}
  end

  def handle_event("save", params, %{assigns: %{company: %{id: company_id}}} = socket) do
    statuses = Map.get(params, "statuses", [])

    case Workforce.put_working_statuses(
           socket.assigns.current_scope.scope,
           company_id,
           statuses
         ) do
      {:ok, _statuses} ->
        {:noreply,
         socket
         |> select_company(Integer.to_string(company_id))
         |> put_flash(:success, "Working statuses saved.")}

      {:error, :invalid_statuses} ->
        {:noreply, put_flash(socket, :error, "Choose at least one employee status.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Working statuses could not be saved.")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event(
        "reconcile_employments",
        _params,
        %{assigns: %{company: %{id: company_id}}} = socket
      ) do
    case Workforce.reconcile_employments(socket.assigns.current_scope.scope, company_id) do
      {:ok, report} ->
        {:noreply,
         socket
         |> select_company(Integer.to_string(company_id))
         |> put_flash(:success, reconcile_message(report))}

      {:error, :company_archived} ->
        {:noreply, put_flash(socket, :error, "An archived company's records cannot be claimed.")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Claiming also needs permission to view contacts, which hold each employee's person record."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Employment records could not be claimed.")}
    end
  end

  def handle_event("reconcile_employments", _params, socket), do: {:noreply, socket}

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do:
      assign(socket, company: nil, working_statuses: [], freshness_notice: nil)
      |> assign_employment(nil)

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))

    case Workforce.working_statuses(socket.assigns.current_scope.scope, company.id) do
      {:ok, %ReadResult{value: statuses, freshness: freshness}} ->
        socket
        |> assign(
          company: company,
          working_statuses: statuses || [],
          freshness_notice: freshness_notice(freshness)
        )
        |> assign_employment(company.id)

      {:error, :not_found} ->
        socket
        |> assign(company: nil, working_statuses: [], freshness_notice: nil)
        |> assign_employment(nil)
    end
  end

  defp assign_employment(socket, nil),
    do:
      assign(socket,
        employment_counts: nil,
        employment_exceptions: [],
        can_manage_employment?: false
      )

  defp assign_employment(socket, company_id) do
    scope = socket.assigns.current_scope.scope

    counts =
      case Workforce.employment_summary(scope, company_id) do
        {:ok, %ReadResult{value: counts}} -> counts
        {:error, _reason} -> nil
      end

    exceptions =
      case Workforce.employment_exceptions(scope, company_id) do
        {:ok, %ReadResult{value: exceptions}} -> exceptions
        {:error, _reason} -> []
      end

    assign(socket,
      employment_counts: counts,
      employment_exceptions: exceptions,
      can_manage_employment?:
        Authorization.allowed?(scope, company_id, @employment_manage_capability)
    )
  end

  @doc "Operator-facing summary of one claim run."
  @spec reconcile_message(map()) :: String.t()
  def reconcile_message(%{
        claimed: claimed,
        adopted: adopted,
        unchanged: unchanged,
        unclaimed: unclaimed
      }) do
    base =
      "Claimed #{claimed}, updated #{adopted} from Core HR, #{unchanged} already current."

    case length(unclaimed) do
      0 -> base
      count -> base <> " #{count} could not be claimed and are listed below."
    end
  end

  @doc "Operator-facing reason a legacy row could not be claimed."
  @spec exception_label(atom()) :: String.t()
  def exception_label(:no_person_mapping), do: "Core has no person record for this employee."
  def exception_label(:invalid_facts), do: "Core's number, type or status is missing."

  def exception_label(:duplicate_affiliation),
    do: "Another employee already holds this person's employment."

  @doc """
  Operator-facing notice for a working-status read that is not current, or
  `nil` when it is current.
  """
  @spec freshness_notice(ReadResult.freshness()) :: String.t() | nil
  def freshness_notice(:current), do: nil

  def freshness_notice({:stale, %DateTime{} = last_confirmed_at}),
    do:
      "These working statuses were last confirmed at " <>
        Calendar.strftime(last_confirmed_at, "%Y-%m-%d %H:%M %Z") <>
        " and may be out of date."

  def freshness_notice({:unavailable, _reason}),
    do: "The current working statuses are unavailable. Saving replaces them with your selection."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="workforce-settings-page" variant={:form}>
        <.header>
          Workforce Settings
          <:subtitle>Choose which employee statuses count as working staff.</:subtitle>
        </.header>

        <div :if={@company == nil} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="workforce-settings-empty"
            title="No active company is available for workforce settings."
          />
        </div>

        <form
          :if={@company}
          id="workforce-company-form"
          phx-change="select_company"
          class="mt-5"
        >
          <label for="workforce-company" class="block text-sm font-medium text-ink-strong">
            Company
          </label>
          <select
            id="workforce-company"
            name="company_id"
            class="mt-2.5 w-full rounded-md border border-line bg-surface px-3 py-1.5 text-sm text-ink"
          >
            <option
              :for={company <- @companies}
              value={company.id}
              selected={company.id == @company.id}
            >
              {company.name}
            </option>
          </select>
        </form>

        <p
          :if={@company && @freshness_notice}
          id="workforce-settings-freshness"
          role="status"
          class="mt-5 rounded-md border border-line bg-surface px-3 py-2 text-sm text-ink"
        >
          {@freshness_notice}
        </p>

        <form :if={@company} id="workforce-settings-form" phx-submit="save" class="mt-5 space-y-5">
          <fieldset class="rounded-xl border border-line bg-surface p-4">
            <legend class="text-sm font-medium text-ink-strong">Working employee statuses</legend>
            <p class="mt-0.5 text-xs text-ink-subtle">
              Employees in these statuses are visible to People capabilities and as supervisors.
            </p>
            <label
              :for={status <- Workforce.employee_statuses()}
              class="mt-2.5 flex items-center gap-2 text-sm text-ink"
            >
              <input
                type="checkbox"
                id={"workforce-status-#{status}"}
                name="statuses[]"
                value={status}
                checked={status in @working_statuses}
              />
              {status_label(status)}
            </label>
          </fieldset>

          <div class="flex justify-end">
            <.button id="workforce-settings-save" type="submit" variant="primary">Save</.button>
          </div>
        </form>

        <section
          :if={@company && @employment_counts}
          id="workforce-employment-records"
          class="mt-5 rounded-xl border border-line bg-surface p-4"
        >
          <h2 class="text-sm font-medium text-ink-strong">Employment records</h2>
          <p class="mt-0.5 text-xs text-ink-subtle">
            People owns employee numbers, employment types, statuses and dates. Existing
            Core HR records are claimed automatically; Core's columns remain a mirror.
          </p>
          <dl class="mt-2.5 grid grid-cols-2 gap-x-4 gap-y-1 text-sm text-ink sm:grid-cols-4">
            <div>
              <dt class="text-xs text-ink-subtle">Employees</dt>
              <dd id="workforce-employment-total">{@employment_counts.total}</dd>
            </div>
            <div>
              <dt class="text-xs text-ink-subtle">Held by People</dt>
              <dd id="workforce-employment-people">{@employment_counts.people}</dd>
            </div>
            <div>
              <dt class="text-xs text-ink-subtle">Not claimed yet</dt>
              <dd id="workforce-employment-unclaimed">{@employment_counts.core_legacy}</dd>
            </div>
            <div>
              <dt class="text-xs text-ink-subtle">Changed in Core HR since claimed</dt>
              <dd id="workforce-employment-drift">{@employment_counts.legacy_drift}</dd>
            </div>
          </dl>
          <div :if={@can_manage_employment?} class="mt-2.5 flex justify-end">
            <.button id="workforce-employment-claim" type="button" phx-click="reconcile_employments">
              Claim again from Core HR
            </.button>
          </div>
          <div :if={@employment_exceptions != []} id="workforce-employment-exceptions" class="mt-4">
            <h3 class="text-xs font-medium text-ink-strong">Not claimed</h3>
            <ul class="mt-1 divide-y divide-line text-sm text-ink">
              <li
                :for={entry <- @employment_exceptions}
                id={"workforce-employment-exception-#{entry.employee_id}"}
                class="py-1"
              >
                {entry.full_name} ({entry.employee_number}): {exception_label(entry.reason)}
              </li>
            </ul>
          </div>
        </section>
      </.page>
    </Layouts.app>
    """
  end

  defp status_label(status), do: String.capitalize(status)
end
