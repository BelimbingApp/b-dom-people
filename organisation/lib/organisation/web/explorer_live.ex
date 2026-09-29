defmodule Bilimbi.People.Organisation.Web.ExplorerLive do
  @moduledoc "A bounded, company-scoped position explorer."

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Organisation

  @capability "people.organisation.view"
  @manage_capability "people.organisation.manage"
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        {:error, :unauthorized} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Organisation")
     |> assign(:active_nav, "people.team.organisation")
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = selected_company(socket.assigns.companies, Map.get(params, "company_id"))
    day = selected_day(Map.get(params, "as_of"))
    page = selected_page(Map.get(params, "page"))
    page_size = selected_page_size(Map.get(params, "page_size"))

    {positions, total} =
      if company do
        with {:ok, count} <-
               Organisation.count_positions(socket.assigns.current_scope.scope, company.id),
             {:ok, values} <-
               Organisation.positions(socket.assigns.current_scope.scope, company.id, day,
                 page: page,
                 page_size: page_size
               ) do
          {values, count}
        else
          {:error, _reason} -> {[], 0}
        end
      else
        {[], 0}
      end

    filters =
      to_form(
        %{
          "company_id" => company && company.id,
          "as_of" => Date.to_iso8601(day),
          "perPage" => page_size
        },
        as: "filters"
      )

    page_data = %{
      page: page,
      page_size: page_size,
      total_entries: total,
      total_pages: ceil(total / page_size)
    }

    can_manage? =
      company != nil and
        match?(
          {:ok, _},
          Company.authorize_company_target(
            socket.assigns.current_scope.actor,
            company.id,
            @manage_capability
          )
        )

    {:noreply,
     socket
     |> assign(:company, company)
     |> assign(:can_manage?, can_manage?)
     |> assign(:as_of, day)
     |> assign(:page, page)
     |> assign(:page_size, page_size)
     |> assign(:page_data, page_data)
     |> assign(:filters_form, filters)
     |> assign(:positions, positions)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    company_id = Map.get(filters, "company_id", "")
    as_of = Map.get(filters, "as_of", "")
    page_size = Map.get(filters, "perPage", "50")

    {:noreply,
     push_patch(socket,
       to: ~p"/people/organisation?company_id=#{company_id}&as_of=#{as_of}&page_size=#{page_size}"
     )}
  end

  def handle_event("page", %{"page" => page}, %{assigns: %{company: company}} = socket)
      when not is_nil(company) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/people/organisation?company_id=#{company.id}&as_of=#{Date.to_iso8601(socket.assigns.as_of)}&page=#{page}&page_size=#{socket.assigns.page_size}"
     )}
  end

  def handle_event(
        "end_assignment",
        %{"assignment_id" => assignment_id, "effective_to" => effective_to},
        %{assigns: %{company: company}} = socket
      )
      when not is_nil(company) do
    result =
      with {id, ""} <- Integer.parse(assignment_id) do
        Organisation.end_assignment(
          socket.assigns.current_scope.actor,
          company.id,
          id,
          effective_to
        )
      end

    socket =
      case result do
        {:ok, _assignment} -> put_flash(socket, :info, "Assignment ended.")
        _error -> put_flash(socket, :error, "The assignment could not be ended on that date.")
      end

    {:noreply,
     push_patch(socket,
       to:
         ~p"/people/organisation?company_id=#{company.id}&as_of=#{Date.to_iso8601(socket.assigns.as_of)}&page=#{socket.assigns.page}&page_size=#{socket.assigns.page_size}"
     )}
  end

  defp selected_company([], _), do: nil
  defp selected_company([first | _], nil), do: first

  defp selected_company(companies, id),
    do: Enum.find(companies, &(Integer.to_string(&1.id) == id))

  defp selected_day(nil), do: Date.utc_today()

  defp selected_day(value) do
    case Date.from_iso8601(value) do
      {:ok, day} -> day
      _ -> Date.utc_today()
    end
  end

  defp selected_page(value) do
    case Integer.parse(value || "1") do
      {page, ""} when page > 0 and page <= 10_000 -> page
      _ -> 1
    end
  end

  defp selected_page_size(value) do
    case Integer.parse(value || "50") do
      {size, ""} when size in [25, 50, 100] -> size
      _ -> @page_size
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="organisation-explorer-page" variant={:list}>
        <.header>
          Organisation
          <:subtitle>Positions and their holders on the selected date.</:subtitle>
        </.header>

        <.empty_state
          :if={@companies == []}
          id="organisation-no-company"
          title="No active company is available."
        />

        <div :if={@companies != []}>
          <.filter_toolbar id="organisation-filter" form={@filters_form} event="filter">
            <:control
              type={:select}
              field={@filters_form[:company_id]}
              id="organisation-company"
              label="Company"
              options={Enum.map(@companies, &{&1.name, &1.id})}
            />
            <:control type={:date} field={@filters_form[:as_of]} id="organisation-date" label="As of" />
          </.filter_toolbar>

          <.empty_state
            :if={@company == nil}
            id="organisation-unavailable"
            title="This company is unavailable."
          />

          <.empty_state
            :if={@company && @positions == []}
            id="organisation-empty"
            title="No positions have been recorded for this company."
          />

          <div :if={@positions != []} id="organisation-positions" class="mt-6 space-y-3">
            <article :for={position <- @positions} class="rounded-xl border border-line bg-surface p-4">
              <h2 class="font-semibold">{position.title || position.code}</h2>
              <p class="text-sm text-ink-muted">{position.code}</p>
              <p class="text-sm">
                <span :if={position.vacant?}>Vacant</span>
                <span :if={!position.vacant?}>Substantive holder assigned</span>
                <span :if={position.parent_reference}>
                  · Reports to position {position.parent_reference.stable_id}
                </span>
              </p>
              <div :for={assignment <- position.assignments} class="flex flex-wrap items-center gap-2 text-sm">
                <span>
                  {String.capitalize(assignment.kind)} · Employee {assignment.employee_reference.stable_id}
                </span>
                <form
                  :if={@can_manage?}
                  id={"end-assignment-#{assignment.reference.stable_id}"}
                  phx-submit="end_assignment"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="assignment_id" value={assignment.reference.stable_id} />
                  <input
                    type="date"
                    name="effective_to"
                    value={Date.to_iso8601(@as_of)}
                    aria-label="Last day of assignment"
                    required
                    class="rounded-md border border-line bg-surface px-2 py-1 text-sm"
                  />
                  <button type="submit" class="rounded-md border border-line px-2 py-1 text-sm">
                    End
                  </button>
                </form>
              </div>
              <p :if={position.assignments_incomplete?} class="text-sm text-warning-ink">
                More assignments exist beyond this page's display limit.
              </p>
            </article>
          </div>

          <.pagination
            :if={@company}
            id="organisation-pagination"
            page={@page_data}
            page_sizes={[25, 50, 100]}
            filters_form={@filters_form}
            filters_event="filter"
            page_event="page"
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
