defmodule Bilimbi.People.Training.Web.PassportLive do
  @moduledoc "My and Team learning passports within Training records."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Base.Authz
  alias Bilimbi.People.Training.Passport
  alias Bilimbi.People.Training.Web.Support

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, document: nil)}
  @impl true
  def handle_params(params, uri, socket) do
    audience = if URI.parse(uri).path == "/people/training/records/team", do: :team, else: :self

    path =
      if audience == :team,
        do: "/people/training/records/team",
        else: "/people/training/records/my"

    companies = Support.companies(socket.assigns.current_scope, Passport.capability(audience))

    {:noreply,
     socket
     |> assign(
       page_title: "Training records",
       active_nav: "people.development.training_records",
       audience: audience,
       path: path,
       companies: companies,
       company: Support.company(companies, params),
       params: params,
       document: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("generate", _, %{assigns: %{can_generate?: false}} = socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         "You cannot generate this passport. Current workforce and document generation access are required."
       )}

  def handle_event("generate", _, socket) do
    case Passport.generate(
           socket.assigns.current_scope.scope,
           socket.assigns.company.id,
           socket.assigns.audience,
           socket.assigns.employee_id
         ) do
      {:ok, document} ->
        {:noreply,
         socket |> assign(document: document) |> put_flash(:success, "Passport generated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Support.message(reason))}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket),
    do: {:noreply, push_patch(socket, to: socket.assigns.path <> "?" <> URI.encode_query(params))}

  def handle_event("page", %{"page" => page}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           socket.assigns.path <>
             "?" <> URI.encode_query(Map.put(socket.assigns.params, "page", page))
       )}

  defp load(socket) do
    a = socket.assigns
    scope = a.current_scope.scope

    result =
      if a.company,
        do: Passport.employees(scope, a.company.id, a.audience),
        else: {:error, :company_unavailable}

    {employees, directory, error} =
      case result do
        {:ok, directory} -> {directory.employees, directory, nil}
        {:error, reason} -> {[], nil, Support.message(reason)}
      end

    employee =
      if a.params["employee_id"],
        do: Enum.find(employees, &(&1.reference.stable_id == a.params["employee_id"])),
        else: List.first(employees)

    employee_id = if employee, do: employee.reference.stable_id

    result =
      if employee,
        do: Passport.read(scope, a.company.id, a.audience, employee_id, a.params),
        else: nil

    {passport, error} =
      case result do
        {:ok, passport} ->
          {passport, error}

        {:error, reason} ->
          {nil, Support.message(reason)}

        nil ->
          {nil,
           error ||
             if(a.params["employee_id"], do: "That employee is not available in this view.")}
      end

    empty_page = %{
      entries: [],
      page: 1,
      page_size: Passport.page_size(a.params),
      total_entries: 0,
      total_pages: 0
    }

    can_generate =
      passport != nil and passport.workforce.freshness == :current and
        Authz.can(scope, "people.training.passport.generate").allowed

    assign(socket,
      employees: employees,
      employee_id: employee_id,
      passport: passport,
      records: if(passport, do: passport.page, else: empty_page),
      error: error,
      warning: if(directory, do: Passport.workforce_warning(directory.workforce)),
      can_generate?: can_generate,
      can_my?: Authz.can(scope, Passport.capability(:self)).allowed,
      can_team?: Authz.can(scope, Passport.capability(:team)).allowed,
      can_records?: Authz.can(scope, "people.training.records.workspace.view").allowed,
      can_learning?: Authz.can(scope, "people.training.learning.view").allowed,
      filters:
        to_form(
          %{
            "company_id" => if(a.company, do: a.company.id, else: ""),
            "employee_id" => employee_id || "",
            "perPage" => a.params["perPage"] || "25"
          },
          as: :filters
        )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page class="space-y-4">
        <.header>Training records</.header>
        <nav aria-label="Training records" class="flex flex-wrap gap-4">
          <.link :if={@can_my?} navigate="/people/training/records/my" aria-current={if @audience == :self, do: "page"}>My passport</.link>
          <.link :if={@can_team?} navigate="/people/training/records/team" aria-current={if @audience == :team, do: "page"}>Team passports</.link>
          <.link :if={@can_records?} navigate="/people/training/records">Attendance & evidence</.link>
          <.link :if={@can_learning?} navigate="/people/training/my">Learning requests & evaluations</.link>
        </nav>
        <.filter_toolbar id="passport-filters" form={@filters} event="filter">
          <:control type={:select} id="passport-company" field={@filters[:company_id]} label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
          <:control type={:select} id="passport-employee" field={@filters[:employee_id]} label="Employee" options={Enum.map(@employees, &{&1.display_name, &1.reference.stable_id})} />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <.alert :if={@warning} kind={:warning}>{@warning}</.alert>
        <.empty_state :if={@employees == [] and is_nil(@error)} title="No team employees" reason="Only employees currently reporting directly to your linked employee appear here." />
        <section :if={@passport} class="space-y-3">
          <h2 class="font-semibold">{@passport.employee.display_name}</h2>
          <p>Latest attendance revisions. Evidence remains attached to the revision on which it was recorded.</p>
          <.table id="passport-records" rows={@records.entries}>
            <:col :let={row} label="Course">{row.course}</:col>
            <:col :let={row} label="Session">{row.session}</:col>
            <:col :let={row} label="Completed"><.datetime id={"passport-date-#{row.fact_id}"} value={row.ends_at} /></:col>
            <:col :let={row} label="Attendance">{row.status} (revision {row.revision})</:col>
            <:col :let={row} label="Evidence"><a :for={document <- row.evidence} href={@path <> "/evidence/#{@company.id}/#{document.artifact_id}"}>Download evidence PDF</a><span :if={row.evidence == []}>No evidence on this revision</span></:col>
            <:empty title="No training records yet" reason="An authorized training operator can confirm session attendance and attach evidence." />
          </.table>
          <.pagination id="passport-pagination" page={@records} filters_form={@filters} filters_event="filter" />
          <.button :if={@can_generate?} phx-click="generate" phx-disable-with="Generating…">Generate passport PDF</.button>
          <p :if={not @can_generate?}>Document generation requires current workforce data and passport generation access. Ask an operator to check your access or connection.</p>
          <a :if={@document} href={@path <> "/document/#{@company.id}/#{@document.id}"}>Download generated passport PDF</a>
        </section>
      </.page>
    </Layouts.app>
    """
  end
end
