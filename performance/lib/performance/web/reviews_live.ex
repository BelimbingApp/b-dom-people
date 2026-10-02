defmodule Bilimbi.People.Performance.Web.ReviewsLive do
  @moduledoc "Company-scoped performance planning and authored review history."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Performance
  alias Bilimbi.People.Performance.WebSupport, as: Support

  @description_events ~w(create_description request_publish_description)
  @target_events ~w(create_definition create_target)
  @review_events ~w(create_observation create_review)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Performance reviews")
     |> assign(:active_nav, "people.development.performance")
     |> assign(:selected, nil)
     |> assign(:pending, nil)
     |> stream(:reviews, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in ~w(descriptions kpis evidence), do: params["tab"], else: "reviews"

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:page, Support.integer(params["page"]) || 1)
     |> assign(
       :page_size,
       if(Support.integer(params["page_size"]) in [10, 25, 50, 100],
         do: Support.integer(params["page_size"]),
         else: 25
       )
     )
     |> assign(:selected, nil)
     |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_description?: false}} = socket)
      when event in @description_events, do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_target?: false}} = socket)
      when event in @target_events, do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_review?: false}} = socket)
      when event in @review_events, do: forbidden(socket)

  def handle_event("review_target", _params, %{assigns: %{can_review_target?: false}} = socket),
    do: forbidden(socket)

  def handle_event(
        "request_publish_target",
        _params,
        %{assigns: %{can_publish_target?: false}} = socket
      ),
      do: forbidden(socket)

  def handle_event("request_release", _params, %{assigns: %{can_release?: false}} = socket),
    do: forbidden(socket)

  def handle_event("confirm_publication", _params, %{assigns: %{can_confirm?: false}} = socket),
    do: forbidden(socket)

  def handle_event("create_description", %{"record" => attrs}, socket) do
    attrs = Support.attrs(attrs)

    profile =
      Enum.find(socket.assigns.choices.profiles, &(&1.id == Support.integer(attrs["profile_id"])))

    attrs =
      Map.put(
        attrs,
        "competency_links",
        if(profile, do: [%{"id" => profile.id, "version" => profile.version}], else: [])
      )

    result(socket, Performance.draft_description(scope(socket), company(socket), attrs))
  end

  def handle_event("create_definition", %{"record" => attrs}, socket),
    do:
      result(socket, Performance.define_kpi(scope(socket), company(socket), Support.attrs(attrs)))

  def handle_event("create_target", %{"record" => attrs}, socket) do
    attrs = Support.attrs(attrs)

    outcome =
      if attrs["supersedes_id"],
        do:
          Performance.amend_target(scope(socket), company(socket), attrs["supersedes_id"], attrs),
        else: Performance.propose_target(scope(socket), company(socket), attrs)

    result(socket, outcome)
  end

  def handle_event("create_observation", %{"record" => attrs}, socket) do
    attrs = Support.attrs(attrs)

    outcome =
      if attrs["supersedes_id"],
        do:
          Performance.correct_observation(
            scope(socket),
            company(socket),
            attrs["supersedes_id"],
            attrs
          ),
        else: Performance.record_observation(scope(socket), company(socket), attrs)

    result(socket, outcome)
  end

  def handle_event("create_review", %{"record" => attrs}, socket) do
    attrs = Support.attrs(attrs)

    outcome =
      if attrs["supersedes_id"],
        do:
          Performance.correct_review(
            scope(socket),
            company(socket),
            attrs["supersedes_id"],
            attrs
          ),
        else: Performance.draft_review(scope(socket), company(socket), attrs)

    result(socket, outcome)
  end

  def handle_event("review_target", %{"record_id" => id, "note" => note}, socket),
    do:
      result(
        socket,
        Performance.review_target(scope(socket), company(socket), Support.integer(id), note)
      )

  def handle_event("request_publish_description", %{"id" => id}, socket),
    do: confirm(socket, :description, id)

  def handle_event("request_publish_target", %{"id" => id}, socket),
    do: confirm(socket, :target, id)

  def handle_event("request_release", %{"id" => id}, socket), do: confirm(socket, :review, id)

  def handle_event("cancel_publication", _params, socket),
    do: {:noreply, assign(socket, :pending, nil)}

  def handle_event("confirm_publication", _params, socket) do
    pending = socket.assigns.pending
    socket = assign(socket, :pending, nil)

    outcome =
      case pending do
        %{kind: :description, id: id} ->
          Performance.publish_description(scope(socket), company(socket), id)

        %{kind: :target, id: id} ->
          Performance.publish_target(scope(socket), company(socket), id)

        %{kind: :review, id: id} ->
          Performance.release_review(scope(socket), company(socket), id)

        _ ->
          {:error, :not_found}
      end

    result(socket, outcome)
  end

  def handle_event("select", %{"id" => id}, socket) do
    case Performance.review(scope(socket), company(socket), Support.integer(id)) do
      {:ok, record} -> {:noreply, assign(socket, :selected, record)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Support.message(reason))}
    end
  end

  def handle_event("paginate", params, socket), do: navigate(socket, params)
  def handle_event("filter", %{"filters" => params}, socket), do: navigate(socket, params)

  defp navigate(socket, params) do
    query = %{
      tab: socket.assigns.tab,
      page: params["page"] || 1,
      page_size: params["perPage"] || params["page_size"] || socket.assigns.page_size
    }

    {:noreply, push_patch(socket, to: "/people/performance?" <> URI.encode_query(query))}
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company(socket), do: Bilimbi.Base.Tenancy.Scope.actor(scope(socket)).company_id

  defp forbidden(socket),
    do: {:noreply, put_flash(socket, :error, Support.message(:unauthorized))}

  defp result(socket, {:ok, _}),
    do: {:noreply, socket |> put_flash(:success, "Record saved.") |> load()}

  defp result(socket, {:error, reason}),
    do: {:noreply, put_flash(socket, :error, Support.message(reason))}

  defp confirm(socket, kind, id) do
    records =
      case kind do
        :description -> socket.assigns.planning.descriptions
        :target -> socket.assigns.planning.targets
        :review -> socket.assigns.planning.drafts
      end

    case Enum.find(records, &(&1.id == Support.integer(id))) do
      nil ->
        {:noreply, put_flash(socket, :error, Support.message(:not_found))}

      record ->
        {:noreply,
         socket |> clear_flash() |> assign(:pending, %{kind: kind, id: record.id, record: record})}
    end
  end

  defp load(socket) do
    actor = scope(socket)
    id = company(socket)

    permissions = [
      can_description?: "people.performance.descriptions.manage",
      can_target?: "people.performance.kpis.submit",
      can_review?: "people.performance.reviews.submit",
      can_review_target?: "people.performance.kpis.review",
      can_publish_target?: "people.performance.kpis.approve",
      can_release?: "people.performance.reviews.approve"
    ]

    socket =
      Enum.reduce(permissions, socket, fn {name, cap}, socket ->
        assign(socket, name, Performance.allowed?(actor, id, cap))
      end)

    socket =
      assign(
        socket,
        :can_confirm?,
        socket.assigns.can_description? or socket.assigns.can_publish_target? or
          socket.assigns.can_release?
      )
      |> assign(:record_form, to_form(%{}, as: :record))
      |> assign(
        :filter_form,
        to_form(%{"perPage" => to_string(socket.assigns.page_size)}, as: :filters)
      )

    with {:ok, list} <-
           Performance.reviews(actor, id,
             page: socket.assigns.page,
             page_size: socket.assigns.page_size
           ),
         {:ok, planning} <- Performance.planning_records(actor, id),
         {:ok, choices} <- Performance.planning_choices(actor, id) do
      socket
      |> assign(:unavailable, nil)
      |> assign(:total, list.total)
      |> assign(:page, list.page)
      |> assign(:planning, planning)
      |> assign(:choices, choices)
      |> stream(:reviews, list.rows, reset: true)
    else
      {:error, reason} ->
        socket
        |> assign(:unavailable, Support.message(reason))
        |> assign(:total, 0)
        |> assign(:planning, %{
          descriptions: [],
          definitions: [],
          targets: [],
          observations: [],
          drafts: [],
          prior_reviews: []
        })
        |> assign(:choices, %{
          employees: [],
          positions: [],
          profiles: [],
          descriptions: [],
          targets: [],
          names: %{}
        })
        |> stream(:reviews, [], reset: true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>Performance reviews</.header>
        <nav class="my-4 flex flex-wrap gap-4" aria-label="Performance tasks">
          <.link :for={{tab, label} <- [{"reviews", "Reviews"}, {"descriptions", "Position descriptions"}, {"kpis", "KPIs"}, {"evidence", "Evidence"}]}
            patch={"/people/performance?tab=" <> tab} aria-current={if @tab == tab, do: "page", else: nil}>{label}</.link>
        </nav>
        <.empty_state :if={@unavailable} id="performance-unavailable" title="Performance is unavailable" reason={@unavailable} />
        <div :if={!@unavailable}>
          <%= if @tab == "reviews" do %>
            <.section_heading title="Reviews you authored" />
            
            <.table id="performance-reviews" rows={@streams.reviews}>
              <:col :let={{_id, row}} label="Employee">{employee_name(@choices, row.employee_id)}</:col>
              <:col :let={{_id, row}} label="Period">{row.period_start} – {row.period_end}</:col>
              <:col :let={{_id, row}} label="Version">{row.version}</:col>
              <:col :let={{_id, row}} label="State">{row.status}</:col>
              <:col :let={{_id, row}} label="Outcome">{row.outcome}</:col>
              <:action :let={{_id, row}}><button phx-click="select" phx-value-id={row.id}>Read</button></:action>
              <:empty :if={@total == 0}><.empty_state id="performance-empty" title="No reviews authored" reason="Record evidence and communicated targets before drafting a review." /></:empty>
            </.table>
            <.pagination id="performance-pagination" page={%{page: @page, page_size: @page_size, total_entries: @total, total_pages: ceil(@total / @page_size)}} filters_form={@filter_form} filters_event="filter" page_event="paginate" page_sizes={[10,25,50,100]} />
            <.card :if={@selected} id="performance-detail" inner_class="p-5 sm:p-6">
              <.section_heading title={"Review version #{@selected.version}"} />
              <.list>
                <:item title="Rationale">{@selected.rationale}</:item>
                <:item title="Cutoff"><.datetime id="review-cutoff" value={@selected.cutoff_at} /></:item>
                <:item title="Correction">{@selected.change_reason || "Original version"}</:item>
                <:item title="Released"><.datetime id="review-released" :if={@selected.released_at} value={@selected.released_at} /><span :if={!@selected.released_at}>Pending independent release</span></:item>
              </.list>
              <p :for={row <- @selected.observations} id={"pinned-evidence-#{row.id}"} class="mt-3 text-sm">{row.evidence} · {row.source_reference} · {row.source_version}</p>
              <p :for={row <- @selected.targets} id={"pinned-target-#{row.id}"} class="mt-3 text-sm">Target version {row.version}: {row.target}</p>
              <p :for={row <- @selected.responses} id={"review-response-#{row.id}"} class="mt-3 text-sm">{row.response}</p>
            </.card>
            <.section_heading :if={@can_release?} title="Independent release queue" />
            <.table :if={@can_release?} id="performance-release-queue" rows={@planning.drafts} row_id={&"release-#{&1.id}"}>
              <:col :let={row} label="Employee">{employee_name(@choices, row.employee_id)}</:col>
              <:col :let={row} label="Rationale">{row.rationale}</:col>
              <:action :let={row}><button phx-click="request_release" phx-value-id={row.id}>Release</button></:action>
              <:empty :if={@planning.drafts == []}><.empty_state title="No drafts awaiting release" /></:empty>
            </.table>
            <.record_editor :if={@can_review?} id="review-form" title="Draft a review or correction" event="create_review" form={@record_form}
              planning={@planning} choices={@choices} fields={~w(employee_id description_id period_start period_end cutoff_at outcome rationale observation_ids target_ids supersedes_id change_reason)} />
            <.empty_state :if={!@can_review?} title="Review drafting is read-only" reason="An operator must grant review submission access to draft reviews for your direct reports." />
          <% end %>
          <%= if @tab == "descriptions" do %>
            <.section_heading title="Position description versions" />
            <.table id="performance-descriptions" rows={@planning.descriptions} row_id={&"description-#{&1.id}"}>
              <:col :let={row} label="Code">{row.code}</:col>
              <:col :let={row} label="Version">{row.version}</:col>
              <:col :let={row} label="Purpose">{row.purpose}</:col>
              <:col :let={row} label="Effective">{row.effective_from} – {row.effective_to || "Open"}</:col>
              <:col :let={row} label="State">{row.status}</:col>
              <:action :let={row}><button :if={@can_description? && row.status == "draft"} phx-click="request_publish_description" phx-value-id={row.id}>Publish</button></:action>
              <:empty :if={@planning.descriptions == []}><.empty_state title="No position descriptions" reason="Create a description linked to a position and published competency profile." /></:empty>
            </.table>
            <.record_editor :if={@can_description?} id="description-form" title="New position description version" event="create_description" form={@record_form}
              planning={@planning} choices={@choices} fields={~w(code version position_id position_version effective_from effective_to purpose responsibilities duties authority qualifications profile_id)} />
            <.empty_state :if={!@can_description?} title="Description management unavailable" reason="An operator must grant description management access." />
          <% end %>
          <%= if @tab == "kpis" do %>
            <.section_heading title="KPI definition versions" />
            <.table id="performance-definitions" rows={@planning.definitions} row_id={&"definition-#{&1.id}"}>
              <:col :let={row} label="Code">{row.code}</:col><:col :let={row} label="Version">{row.version}</:col>
              <:col :let={row} label="Name">{row.name}</:col><:col :let={row} label="Measure">{row.measure} ({row.unit})</:col>
              <:empty :if={@planning.definitions == []}><.empty_state title="No KPI definitions" /></:empty>
            </.table>
            <.record_editor :if={@can_target?} id="definition-form" title="New measurement version" event="create_definition" form={@record_form}
              planning={@planning} choices={@choices} fields={~w(code version name purpose unit measure source_reference calculation_version direction rubric precision interpretation)} />
            <.section_heading title="Individual targets" />
            <.table id="performance-targets" rows={@planning.targets} row_id={&"target-#{&1.id}"}>
              <:col :let={row} label="Employee">{employee_name(@choices, row.employee_id)}</:col><:col :let={row} label="Target">{row.target}</:col>
              <:col :let={row} label="Version">{row.version}</:col><:col :let={row} label="State">{row.status}{if row.confidential, do: " · confidential"}</:col>
              <:action :let={row}>
                <.form :if={@can_review_target? && row.status == "proposed"} for={%{}} id={"target-review-#{row.id}"} phx-submit="review_target">
                  <input type="hidden" name="record_id" value={row.id}/><.input name="note" label="Review rationale" value="" required/><.button>Review</.button>
                </.form>
                <button :if={@can_publish_target? && row.status == "reviewed" && !row.confidential} phx-click="request_publish_target" phx-value-id={row.id}>Communicate</button>
              </:action>
              <:empty :if={@planning.targets == []}><.empty_state title="No targets available" /></:empty>
            </.table>
            <.record_editor :if={@can_target?} id="target-form" title="Propose a target or amendment" event="create_target" form={@record_form}
              planning={@planning} choices={@choices} fields={~w(definition_id employee_id target period_start period_end effective_from confidential supersedes_id change_reason)} />
            <.empty_state :if={!@can_target?} title="Target proposals are read-only" reason="An operator must grant KPI submission access." />
          <% end %>
          <%= if @tab == "evidence" do %>
            <.section_heading title="Evidence you recorded" />
            <.table id="performance-observations" rows={@planning.observations} row_id={&"observation-#{&1.id}"}>
              <:col :let={row} label="Source">{row.source_reference}</:col><:col :let={row} label="Employee">{employee_name(@choices, row.employee_id)}</:col>
              <:col :let={row} label="Evidence">{row.evidence}</:col><:col :let={row} label="Source version">{row.source_version}</:col>
              <:empty :if={@planning.observations == []}><.empty_state title="No observations recorded" /></:empty>
            </.table>
            <.record_editor :if={@can_review?} id="observation-form" title="Record evidence or a correction" event="create_observation" form={@record_form}
              planning={@planning} choices={@choices} fields={~w(employee_id window_start window_end evidence source_reference source_version supersedes_id change_reason)} />
            <.empty_state :if={!@can_review?} title="Evidence recording is read-only" reason="An operator must grant review submission access." />
          <% end %>
        </div>
        <.confirm_dialog :if={@pending} id="performance-publication" consequence="This version will become an immutable published record."
          detail="Corrections require a new version; existing history is retained."
          confirm="Publish" working="Publishing…" on_confirm={JS.push("confirm_publication")} on_cancel={JS.push("cancel_publication")} />
      </.page>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:event, :string, required: true)
  attr(:form, :any, required: true)
  attr(:fields, :list, required: true)
  attr(:planning, :map, required: true)
  attr(:choices, :map, required: true)

  defp record_editor(assigns) do
    ~H"""
    <details class="mt-5">
      <summary class="cursor-pointer text-sm text-link">{@title}</summary>
      <.page variant={:form}>
        <.form for={@form} id={@id} phx-submit={@event} class="mt-4">
          <%= for field <- @fields do %>
            <.input :if={options(field, @id, @planning, @choices) == nil} field={@form[field]} label={label(field)} type={input_type(field)} />
            <.input :if={options(field, @id, @planning, @choices) != nil} field={@form[field]} label={label(field)} type="select"
              options={options(field, @id, @planning, @choices)} multiple={field in ~w(observation_ids target_ids)} />
          <% end %>
          <.button phx-disable-with="Saving…">Save</.button>
        </.form>
      </.page>
    </details>
    """
  end

  defp input_type("confidential"), do: "checkbox"
  defp input_type("cutoff_at"), do: "datetime-local"

  defp input_type(field)
       when field in ~w(period_start period_end effective_from effective_to window_start window_end),
       do: "date"

  defp input_type(field)
       when field in ~w(purpose responsibilities duties authority qualifications evidence rationale interpretation measure),
       do: "textarea"

  defp input_type(_), do: "text"
  defp label("cutoff_at"), do: "Evidence cutoff (UTC)"
  defp label("observation_ids"), do: "Evidence versions"
  defp label("target_ids"), do: "Communicated target versions"
  defp label("supersedes_id"), do: "Prior version (corrections only)"
  defp label("employee_id"), do: "Employee"
  defp label("position_id"), do: "Position"
  defp label("definition_id"), do: "KPI definition version"
  defp label("description_id"), do: "Position description version"
  defp label("profile_id"), do: "Published competency profile"
  defp label("direction"), do: "Direction (higher, lower, band or rubric)"
  defp label(field), do: field |> String.replace("_", " ") |> String.capitalize()

  defp employee_name(choices, id) do
    Map.get(choices.names, id, "Employee record unavailable")
  end

  defp options("employee_id", _, _, choices),
    do: [{"Choose a direct report", ""} | Enum.map(choices.employees, &{&1.name, &1.id})]

  defp options("position_id", _, _, choices),
    do: [
      {"Choose a position", ""}
      | Enum.map(choices.positions, &{"#{&1.name} · version #{&1.version}", &1.id})
    ]

  defp options("profile_id", _, _, choices),
    do: [
      {"Choose a published profile", ""}
      | Enum.map(choices.profiles, &{"#{&1.name} · version #{&1.version}", &1.id})
    ]

  defp options("definition_id", _, planning, _),
    do: [
      {"Choose a measurement", ""}
      | Enum.map(planning.definitions, &{"#{&1.name} · version #{&1.version}", &1.id})
    ]

  defp options("description_id", _, _, choices),
    do: [
      {"Choose a published description", ""}
      | Enum.map(choices.descriptions, &{"#{&1.code} · version #{&1.version}", &1.id})
    ]

  defp options("observation_ids", _, planning, _),
    do:
      Enum.map(
        planning.observations,
        &{"#{&1.source_reference} · #{&1.source_version}: #{&1.evidence}", &1.id}
      )

  defp options("target_ids", _, _, choices),
    do: Enum.map(choices.targets, &{"#{&1.target} · version #{&1.version}", &1.id})

  defp options("direction", _, _, _),
    do: [
      {"Choose an interpretation", ""},
      {"Higher", "higher"},
      {"Lower", "lower"},
      {"Band", "band"},
      {"Rubric", "rubric"}
    ]

  defp options("supersedes_id", form, planning, choices) do
    records =
      case form do
        "review-form" ->
          Enum.map(
            planning.prior_reviews,
            &{"#{&1.period_start} · #{&1.outcome} · version #{&1.version}", &1.id}
          )

        "target-form" ->
          Enum.map(choices.targets, &{"#{&1.target} · version #{&1.version}", &1.id})

        "observation-form" ->
          Enum.map(
            planning.observations,
            &{"#{&1.source_reference} · #{&1.source_version}", &1.id}
          )
      end

    [{"New record", ""} | records]
  end

  defp options(_, _, _, _), do: nil
end
