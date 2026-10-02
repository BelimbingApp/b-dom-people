defmodule Bilimbi.People.Performance.Web.MyLive do
  @moduledoc "The signed-in employee's communicated targets, released reviews and responses."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Performance
  alias Bilimbi.People.Performance.WebSupport, as: Support

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My performance")
     |> assign(:active_nav, "people.my_work.standing")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page, Support.integer(params["page"]) || 1)
     |> assign(
       :page_size,
       if(Support.integer(params["page_size"]) in [10, 25, 50, 100],
         do: Support.integer(params["page_size"]),
         else: 25
       )
     )
     |> load()}
  end

  @impl true
  def handle_event("save_response", _params, %{assigns: %{can_respond?: false}} = socket),
    do: {:noreply, put_flash(socket, :error, Support.message(:unauthorized))}

  def handle_event("save_response", %{"record_id" => id, "response" => response}, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Bilimbi.Base.Tenancy.Scope.actor(scope).company_id

    case Performance.respond(scope, company_id, Support.integer(id), response) do
      {:ok, _} -> {:noreply, socket |> put_flash(:success, "Response recorded.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Support.message(reason))}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket),
    do: handle_event("paginate", Map.put(params, "page", 1), socket)

  def handle_event("paginate", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         "/people/performance/my?" <>
           URI.encode_query(%{
             page: params["page"] || 1,
             page_size: params["perPage"] || params["page_size"] || socket.assigns.page_size
           })
     )}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Bilimbi.Base.Tenancy.Scope.actor(scope).company_id

    socket =
      assign(
        socket,
        :filter_form,
        to_form(%{"perPage" => to_string(socket.assigns.page_size)}, as: :filters)
      )

    socket =
      assign(
        socket,
        :can_respond?,
        Performance.allowed?(scope, company_id, "people.performance.self.view")
      )

    case Performance.my_records(scope, company_id,
           page: socket.assigns.page,
           page_size: socket.assigns.page_size
         ) do
      {:ok, result} ->
        socket
        |> assign(:unavailable, nil)
        |> assign(:records, result.reviews.rows)
        |> assign(:targets, result.targets)
        |> assign(:total, result.reviews.total)
        |> assign(:page, result.reviews.page)

      {:error, reason} ->
        socket
        |> assign(:unavailable, Support.message(reason))
        |> assign(:records, [])
        |> assign(:targets, [])
        |> assign(:total, 0)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.header>My performance</.header>
        <.empty_state :if={@unavailable} id="my-performance-unavailable" title="Your performance records are unavailable" reason={@unavailable} />
        <div :if={!@unavailable} class="mt-5 space-y-5">
          <.card inner_class="p-5 sm:p-6">
            <.section_heading title="Communicated targets" />
            <.table id="my-performance-targets" rows={@targets} row_id={&"my-target-#{&1.id}"} framed={false}>
              <:col :let={row} label="Target">{row.target}</:col>
              <:col :let={row} label="Period">{row.period_start} – {row.period_end}</:col>
              <:col :let={row} label="Effective from">{row.effective_from}</:col>
              <:col :let={row} label="Version">{row.version}</:col>
              <:empty :if={@targets == []}><.empty_state id="my-targets-empty" title="No targets communicated" reason="Your reviewer must approve and communicate targets before they appear here." /></:empty>
            </.table>
          </.card>
          <.empty_state :if={@records == []} id="my-performance-empty" title="No reviews released" reason="Your review appears after independent release." />
          <.card :for={row <- @records} id={"my-review-#{row.id}"} inner_class="p-5 sm:p-6">
            <.section_heading title={"Review version #{row.version}"} />
            <.list>
              <:item title="Period">{row.period_start} – {row.period_end}</:item>
              <:item title="Outcome">{row.outcome}</:item>
              <:item title="Rationale">{row.rationale}</:item>
              <:item title="Cutoff"><.datetime id={"my-cutoff-#{row.id}"} value={row.cutoff_at} /></:item>
              <:item title="Correction">{row.change_reason || "Original version"}</:item>
            </.list>
            <p :for={evidence <- row.observations} id={"my-evidence-#{row.id}-#{evidence.id}"} class="mt-3 text-sm">{evidence.evidence} · {evidence.source_reference} · {evidence.source_version}</p>
            <p :for={response <- row.responses} id={"my-response-#{response.id}"} class="mt-3 text-sm">{response.response}</p>
            <.form :if={@can_respond? && row.responses == []} for={%{}} id={"response-form-#{row.id}"} phx-submit="save_response" class="mt-4">
              <input type="hidden" name="record_id" value={row.id}/>
              <.input type="textarea" name="response" label="Your response or dispute" value="" required/>
              <.button phx-disable-with="Recording…">Record response</.button>
            </.form>
          </.card>
          <.pagination id="my-performance-pagination" page={%{page: @page, page_size: @page_size, total_entries: @total, total_pages: ceil(@total / @page_size)}} filters_form={@filter_form} filters_event="filter" page_event="paginate" page_sizes={[10,25,50,100]} />
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
