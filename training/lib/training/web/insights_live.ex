defmodule Bilimbi.People.Training.Web.InsightsLive do
  @moduledoc "Bounded attendance insights and authorized course drill."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.{Insights, Passport}
  alias Bilimbi.People.Training.Web.Support
  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, page_title: "Learning insights", active_nav: "people.reports.learning_insights", companies: Support.companies(socket.assigns.current_scope, "people.training.insights.view"))}
  @impl true
  def handle_params(params, _, socket) do
    today = Date.utc_today()
    params = Map.merge(%{"from" => Date.to_iso8601(Date.new!(today.year, 1, 1)), "until" => Date.to_iso8601(today)}, params)
    company = Support.company(socket.assigns.companies, params)
    scope = socket.assigns.current_scope.scope
    drill? = company != nil and Training.allowed?(scope, company.id, "people.training.records.view")
    result = cond do
      company == nil -> {:error, :company_unavailable}
      params["course_id"] -> Insights.drill(scope, company.id, params["course_id"], params)
      true -> Insights.summary(scope, company.id, params)
    end
    empty_page = %{entries: [], page: 1, page_size: Passport.page_size(params), total_entries: 0, total_pages: 0}
    {page, error} = case result do
      {:ok, page} -> {page, nil}
      {:error, reason} -> {empty_page, Support.message(reason)}
    end
    {:noreply, assign(socket, company: company, params: params, page: page, error: error, can_drill?: drill?, drilling?: params["course_id"] != nil, filters: to_form(Map.put(params, "company_id", if(company, do: company.id, else: "")), as: :filters))}
  end
  @impl true
  def handle_event("filter", %{"filters" => params}, socket), do: {:noreply, push_patch(socket, to: "/people/training/insights?" <> URI.encode_query(params))}
  def handle_event("page", %{"page" => page}, socket), do: {:noreply, push_patch(socket, to: "/people/training/insights?" <> URI.encode_query(Map.put(socket.assigns.params, "page", page)))}
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page class="space-y-4">
        <.header>Learning insights</.header>
        <p>Latest session attendance by completion date in UTC. Choose at most 366 days. Small employee cohorts are suppressed; effectiveness scores remain in frozen Effectiveness summaries.</p>
        <.filter_toolbar id="insights-filters" form={@filters} event="filter">
          <:control type={:select} id="insights-company" field={@filters[:company_id]} label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
          <:control type={:date} id="insights-from" field={@filters[:from]} label="From" />
          <:control type={:date} id="insights-until" field={@filters[:until]} label="Through" />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <.table :if={not @drilling?} id="learning-insights" rows={@page.entries}>
          <:col :let={row} label="Course">{row.course}</:col>
          <:col :let={row} label="Employees">{if row.suppressed, do: "Suppressed", else: row.employees}</:col>
          <:col :let={row} label="Confirmed">{row.confirmed || "Suppressed"}</:col>
          <:col :let={row} label="Absent">{row.absent || "Suppressed"}</:col>
          <:col :let={row} label="Records"><.link :if={@can_drill?} patch={"/people/training/insights?" <> URI.encode_query(Map.merge(@params, %{"company_id" => @company.id, "course_id" => row.course_id, "page" => 1}))}>View attendance</.link><span :if={not @can_drill?}>Record-view access required</span></:col>
          <:empty title="No attendance in this period" reason="Choose another completion period or confirm session attendance." />
        </.table>
        <section :if={@drilling?}>
          <.link patch={"/people/training/insights?" <> URI.encode_query(Map.drop(@params, ["course_id", "page"]))}>Back to course totals</.link>
          <.table id="insight-drill" rows={@page.entries}>
            <:col :let={row} label="Employee">{row.employee_id}</:col>
            <:col :let={row} label="Course">{row.course}</:col>
            <:col :let={row} label="Session">{row.session}</:col>
            <:col :let={row} label="Completed"><.datetime id={"drill-date-#{row.fact_id}"} value={row.ends_at} /></:col>
            <:col :let={row} label="Attendance">{row.status}</:col>
            <:empty title="No accessible attendance" reason="Check your record-view access, company and date range." />
          </.table>
        </section>
        <.pagination :if={is_nil(@error)} id="insights-pagination" page={@page} filters_form={@filters} filters_event="filter" />
      </.page>
    </Layouts.app>
    """
  end
end
