defmodule Bilimbi.People.Training.Web.RecordsLive do
  @moduledoc "Session attendance history and private evidence."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.Participation
  alias Bilimbi.People.Training.Web.Support
  @write_events ~w(record upload purge retry_purge)
  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Training records",
       active_nav: nil,
       companies: Support.companies(socket.assigns.current_scope, "people.training.records.view"),
       form: to_form(%{}, as: :record),
       selected_fact: nil
     )
     |> allow_upload(:evidence,
       accept: ~w(.pdf),
       max_entries: 1,
       max_file_size: Bilimbi.Base.Settings.get("artifacts.max_bytes")
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply,
     socket
     |> assign(params: params, company: Support.company(socket.assigns.companies, params))
     |> load()}
  end

  @impl true
  def handle_event(event, _, %{assigns: %{can_write?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change training records.")}

  def handle_event("select_company", %{"filters" => attrs}, socket) do
    {:noreply, push_patch(socket, to: "/people/training/records?" <> URI.encode_query(attrs))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         "/people/training/records?" <>
           URI.encode_query(Map.put(socket.assigns.params, "page", page))
     )}
  end

  def handle_event("record", %{"record" => attrs}, socket) do
    attrs = Map.put(attrs, "session_id", socket.assigns.session_id)

    result =
      Participation.record(socket.assigns.current_scope.scope, socket.assigns.company.id, attrs)

    {:noreply,
     finish(socket, result, "Attendance recorded.")
     |> assign(form: to_form(if(match?({:ok, _}, result), do: %{}, else: attrs), as: :record))
     |> load()}
  end

  def handle_event("select_fact", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(selected_fact: id) |> load()}

  def handle_event("validate_upload", _, socket), do: {:noreply, socket}

  def handle_event("upload", _, socket) do
    if socket.assigns.can_evidence? and socket.assigns.selected_fact do
      results =
        consume_uploaded_entries(socket, :evidence, fn %{path: path}, _entry ->
          {:ok,
           Participation.attach(
             socket.assigns.current_scope.scope,
             socket.assigns.company.id,
             socket.assigns.selected_fact,
             File.read!(path)
           )}
        end)

      result =
        case results do
          [result] -> result
          _ -> {:error, :upload_required}
        end

      {:noreply, finish(socket, result, "Evidence added.") |> load()}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Select an attendance fact and obtain evidence management access."
       )}
    end
  end

  def handle_event("purge", _, socket) do
    result = Participation.purge(socket.assigns.current_scope.scope, socket.assigns.company.id)
    {:noreply, finish(socket, result, "Retention run complete.") |> load()}
  end

  def handle_event("retry_purge", %{"id" => id}, socket) do
    result =
      Participation.retry_purge(socket.assigns.current_scope.scope, socket.assigns.company.id, id)

    {:noreply, finish(socket, result, "Document purged.") |> load()}
  end

  defp finish(socket, {:ok, %{errors: [_ | _]}}, _),
    do:
      put_flash(
        socket,
        :error,
        "Some documents could not be purged. Check retention holds and retry."
      )

  defp finish(socket, {:ok, _}, message),
    do: socket |> clear_flash() |> put_flash(:success, message)

  defp finish(socket, {:error, reason}, _), do: put_flash(socket, :error, Support.message(reason))

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company = socket.assigns.company

    can_manage =
      company != nil and Training.allowed?(scope, company.id, "people.training.records.manage")

    can_evidence =
      company != nil and Training.allowed?(scope, company.id, "people.training.evidence.manage")

    can_retain =
      company != nil and Training.allowed?(scope, company.id, "people.training.retention.manage")

    {sessions, error} =
      if company do
        case Participation.sessions(scope, company.id) do
          {:ok, rows} -> {rows, nil}
          {:error, reason} -> {[], Support.message(reason)}
        end
      else
        {[], "No company is available. Ask an operator to check your access."}
      end

    selected =
      Enum.find(sessions, &(to_string(&1.id) == socket.assigns.params["session_id"])) ||
        List.first(sessions)

    session_id = if selected, do: selected.id

    history =
      if session_id, do: rows(Participation.history(scope, company.id, session_id)), else: []

    selected_fact = Enum.find(history, &(to_string(&1.id) == socket.assigns.selected_fact))

    documents =
      if selected_fact,
        do: rows(Participation.evidence(scope, company.id, selected_fact.id)),
        else: []

    holds = if can_retain, do: rows(Participation.purge_holds(scope, company.id)), else: []
    employees = if can_manage, do: rows(Participation.employees(scope, company.id)), else: []

    assign(socket,
      sessions: sessions,
      session_id: session_id,
      history: history,
      history_page: Support.page(history, socket.assigns.params),
      documents: documents,
      holds: holds,
      employees: employees,
      error: error,
      can_manage?: can_manage,
      can_evidence?: can_evidence,
      can_retain?: can_retain,
      can_write?: can_manage or can_evidence or can_retain,
      selected_fact: if(selected_fact, do: to_string(selected_fact.id)),
      filters:
        to_form(
          %{
            "company_id" => if(company, do: company.id, else: ""),
            "session_id" => session_id || "",
            "perPage" => socket.assigns.params["perPage"] || "25"
          },
          as: :filters
        )
    )
  end

  defp upload_message(:too_large),
    do: "This PDF exceeds the operator-configured document size limit."

  defp upload_message(:not_accepted), do: "Choose a PDF evidence document."
  defp upload_message(:too_many_files), do: "Choose one PDF at a time."
  defp upload_message(_), do: "The upload could not be completed. Choose the file again."

  defp rows({:ok, rows}), do: rows
  defp rows(_), do: []
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page class="space-y-4">
        <.header>Training records</.header>
        <.filter_toolbar id="records-filters" form={@filters} event="select_company">
          <:control type={:select} id="records-company" field={@filters[:company_id]} label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
          <:control type={:select} id="records-session" field={@filters[:session_id]} label="Session" options={Enum.map(@sessions, &{&1.name, &1.id})} />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <.empty_state :if={@sessions == [] and is_nil(@error)} title="No sessions yet" reason="A training operator can add sessions before recording attendance." />
        <p :if={length(@sessions) == 500}>Showing the most recent 500 sessions.</p>
        <p :if={not @can_manage?}>Read-only attendance. Ask an operator with training record management access to confirm or correct attendance.</p>
        <.table id="participation-history" rows={@history_page.entries}>
          <:col :let={fact} label="Employee">{fact.employee_id}</:col>
          <:col :let={fact} label="Revision">{fact.revision}</:col>
          <:col :let={fact} label="Attendance">{fact.status}</:col>
          <:col :let={fact} label="Reason">{fact.reason}</:col>
          <:col :let={fact} label="Recorded by">{fact.actor_user_id}<span :if={fact.impersonator_id}> via {fact.impersonator_id}</span></:col>
          <:col :let={fact} label="Recorded"><.datetime id={"fact-time-#{fact.id}"} value={fact.inserted_at} /></:col>
          <:col :let={fact} label="Evidence"><button phx-click="select_fact" phx-value-id={fact.id}>View evidence</button></:col>
          <:empty title="No attendance yet" reason="Confirmed attendance and corrections appear here as history." />
        </.table>
        <.pagination :if={is_nil(@error)} id="records-pagination" page={@history_page} filters_form={@filters} filters_event="select_company" />
        <.empty_state :if={@can_manage? and @session_id && @employees == []} title="No current employees" reason="Ask an operator to check the workforce before confirming attendance." />
        <.form :if={@can_manage? and @session_id && @employees != []} for={@form} id="participation-form" phx-submit="record" class="space-y-3">
          <.input field={@form[:employee_id]} type="select" label="Employee" options={Enum.map(@employees, &{&1.name, &1.id})} required />
          <.input field={@form[:status]} type="select" label="Attendance" options={[{"Confirmed", "confirmed"}, {"Absent", "absent"}]} required />
          <.input field={@form[:reason]} label="Confirmation or correction reason" required />
          <.input field={@form[:import_key]} label="Record key" required />
          <.button type="submit">Record attendance</.button>
        </.form>
        <section :if={@selected_fact} class="space-y-3">
          <h2>Evidence</h2>
          <.table id="training-evidence" rows={@documents}>
            <:col :let={document} label="Document"><a href={"/people/training/evidence/#{@company.id}/#{document.artifact_id}"}>Download evidence PDF</a></:col>
            <:empty title="No evidence yet" reason="An authorized operator can attach a PDF to this attendance fact." />
          </.table>
          <p :if={not @can_evidence?}>Read-only evidence. Ask an operator with evidence management access to add a document.</p>
          <form :if={@can_evidence?} id="evidence-form" phx-change="validate_upload" phx-submit="upload">
            <.live_file_input upload={@uploads.evidence} />
            <p :for={error <- upload_errors(@uploads.evidence)}>{upload_message(error)}</p>
            <p :for={entry <- @uploads.evidence.entries} :if={upload_errors(@uploads.evidence, entry) != []}>
              <span :for={error <- upload_errors(@uploads.evidence, entry)}>{upload_message(error)}</span>
            </p>
            <.button type="submit">Add evidence</.button>
          </form>
        </section>
        <section :if={@can_retain?} class="space-y-3">
          <h2>Document retention</h2>
          <.button phx-click="purge">Purge expired evidence</.button>
          <.table id="retention-holds" rows={@holds}>
            <:col :let={hold} label="Document">{hold.id}</:col>
            <:col :let={hold} label="Reason">{hold.last_error}</:col>
            <:col :let={hold} label="Attempts">{hold.attempts}</:col>
            <:col :let={hold} label="Action"><button phx-click="retry_purge" phx-value-id={hold.id}>Retry purge</button></:col>
            <:empty title="No retention holds" reason="Expired evidence is maintained by the document service." />
          </.table>
        </section>
      </.page>
    </Layouts.app>
    """
  end
end
