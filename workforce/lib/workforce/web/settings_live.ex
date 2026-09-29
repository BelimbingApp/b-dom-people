defmodule Bilimbi.People.Workforce.Web.SettingsLive do
  @moduledoc """
  Per-company operator settings for the People workforce seam.

  The company list comes from `Company.list_selectable_companies/2` under the
  route capability, so an operator only reaches companies they may manage.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @capability "people.workforce.settings.manage"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
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

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do: assign(socket, company: nil, working_statuses: [], freshness_notice: nil)

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))

    case Workforce.working_statuses(socket.assigns.current_scope.scope, company.id) do
      {:ok, %ReadResult{value: statuses, freshness: freshness}} ->
        assign(socket,
          company: company,
          working_statuses: statuses || [],
          freshness_notice: freshness_notice(freshness)
        )

      {:error, :not_found} ->
        assign(socket, company: nil, working_statuses: [], freshness_notice: nil)
    end
  end

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
            <option :for={company <- @companies} value={company.id} selected={company.id == @company.id}>
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
      </.page>
    </Layouts.app>
    """
  end

  defp status_label(status), do: String.capitalize(status)
end
