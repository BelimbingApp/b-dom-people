defmodule Bilimbi.People.Training.Web.CoursesLive do
  @moduledoc "Company course catalog."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Training
  alias Bilimbi.Base.UI.CommitStatus
  alias Bilimbi.People.Training.Web.Support
  @write_events ~w(open_course create_course set_active edit_description save_course_field)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(CommitStatus.init(socket),
       editing_description: nil,
       page_title: "Courses",
       active_nav: "people.development.courses",
       companies: Support.companies(socket.assigns.current_scope, "people.training.courses.view"),
       modal: false,
       form: to_form(%{}, as: :course)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.company(socket.assigns.companies, params)

    {:noreply,
     socket
     |> assign(company: company, modal: false, params: params, editing_description: nil)
     |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do:
        {:noreply,
         CommitStatus.write_forbidden(socket, "You cannot change this company's courses.")}

  def handle_event("select_company", %{"filters" => attrs}, socket) do
    params = socket.assigns.params |> Map.merge(attrs) |> Map.put("page", "1")
    {:noreply, push_patch(socket, to: "/people/training/courses?" <> URI.encode_query(params))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         "/people/training/courses?" <>
           URI.encode_query(Map.put(socket.assigns.params, "page", page))
     )}
  end

  def handle_event("open_course", _, socket),
    do:
      {:noreply, socket |> clear_flash() |> assign(modal: true, form: to_form(%{}, as: :course))}

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: false)}

  def handle_event("create_course", %{"course" => attrs}, socket) do
    case Training.create_course(
           socket.assigns.current_scope.scope,
           socket.assigns.company.id,
           attrs
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> clear_flash()
         |> assign(modal: false)
         |> put_flash(:success, "Course added.")
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(form: to_form(attrs, as: :course))
         |> put_flash(:error, Support.message(reason))}
    end
  end

  def handle_event("set_active", %{"id" => id, "active" => active}, socket) do
    case Training.update_course(
           socket.assigns.current_scope.scope,
           socket.assigns.company.id,
           Support.integer(id),
           %{active: active == "true"}
         ) do
      {:ok, _} ->
        {:noreply, socket |> clear_flash() |> put_flash(:success, "Course updated.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Support.message(reason))}
    end
  end

  def handle_event("edit_description", %{"field" => field}, socket) do
    editing = if Enum.any?(socket.assigns.courses, &("description:#{&1.id}" == field)), do: field
    {:noreply, assign(socket, editing_description: editing)}
  end

  def handle_event("cancel_description", _, socket),
    do: {:noreply, assign(socket, editing_description: nil)}

  def handle_event("save_course_field", %{"id" => id} = params, socket) do
    id = Support.integer(id)
    fields = %{"name" => :name, "description:#{id}" => :description}

    case CommitStatus.inline_field(params, fields) do
      {:ok, _name, field, value} ->
        result =
          Training.update_course(
            socket.assigns.current_scope.scope,
            socket.assigns.company.id,
            id,
            %{field => value}
          )

        case result do
          {:error, :unauthorized} ->
            {:noreply,
             socket
             |> assign(editing_description: nil)
             |> CommitStatus.write_forbidden("You cannot change this company's courses.")
             |> load()}

          other ->
            status =
              case other do
                {:ok, _} ->
                  :saved

                {:error, %Ecto.Changeset{} = changeset} ->
                  {:error,
                   CommitStatus.refusal_message(to_string(field), field, value, changeset.errors)}

                {:error, reason} ->
                  {:error, Support.message(reason)}
              end

            {:noreply,
             socket
             |> assign(editing_description: nil)
             |> CommitStatus.put("#{id}:#{field}", status)
             |> load()}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp load(socket) do
    company = socket.assigns.company
    scope = socket.assigns.current_scope.scope

    {courses, error} =
      if company do
        case Training.list_courses(scope, company.id) do
          {:ok, records} -> {records, nil}
          {:error, reason} -> {[], Support.message(reason)}
        end
      else
        {[], "No company is available. Ask an operator to check your company access."}
      end

    assign(socket,
      course_page: Support.page(courses, socket.assigns.params),
      courses: courses,
      error: error,
      can_manage?:
        company != nil and error == nil and
          Training.allowed?(scope, company.id, "people.training.courses.manage"),
      filters:
        to_form(
          %{
            "company_id" => if(company, do: to_string(company.id), else: ""),
            "perPage" => socket.assigns.params["perPage"] || "25"
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
        <.header>
          Courses
          <:actions :if={@can_manage?}><.button phx-click="open_course">Add course</.button></:actions>
        </.header>
        <.filter_toolbar id="course-filters" form={@filters} event="select_company">
          <:control type={:select} field={@filters[:company_id]} id="course-company" label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <p :if={not @can_manage? and is_nil(@error)} class="text-sm text-ink-muted">Read-only. Ask an operator with course management access to change the catalog.</p>
        <.table :if={is_nil(@error)} id="courses" rows={@course_page.entries} row_id={&"course-#{&1.id}"}>
          <:col :let={course} label="Course">
            <.inline_edit :if={@can_manage?} id={"course-name-#{course.id}"} value={course.name} name="name" label="Course name" id_value={course.id} save_event="save_course_field" status={@field_status["#{course.id}:name"]} />
            <span :if={not @can_manage?}>{course.name}</span>
          </:col>
          <:col :let={course} label="Code">{course.code}</:col>
          <:col :let={course} label="Description">
            <.inline_long_text id={"course-description-#{course.id}"} field={"description:#{course.id}"} label="Course description" value={course.description || ""} id_value={course.id} editing={@editing_description == "description:#{course.id}"} editable?={@can_manage?} save_event="save_course_field" edit_event="edit_description" cancel_event="cancel_description" allow_empty status={@field_status["#{course.id}:description"]} />
          </:col>
          <:col :let={course} label="Status">{if course.active, do: "Active", else: "Inactive"}</:col>
          <:col :let={course} :if={@can_manage?} label="Actions">
            <button type="button" class="text-link" phx-click="set_active" phx-value-id={course.id} phx-value-active={to_string(not course.active)} phx-disable-with="Saving…">{if course.active, do: "Deactivate", else: "Reactivate"}</button>
          </:col>
          <:empty :if={@course_page.entries == []} title="No courses yet" reason="An operator can add courses for this company." />
        </.table>
        <.pagination :if={is_nil(@error)} id="course-pagination" page={@course_page} filters_form={@filters} filters_event="select_company" />
        <.modal :if={@modal} id="course-modal" title="Add course" on_cancel={JS.push("close_modal")} flash={@flash}>
          <.form for={@form} id="course-form" phx-submit="create_course" class="space-y-3">
            <.input field={@form[:code]} label="Code" required maxlength="80" />
            <.input field={@form[:name]} label="Name" required maxlength="160" />
            <.input field={@form[:description]} type="textarea" label="Description" maxlength="4000" />
            <div class="flex justify-end gap-3"><button type="button" phx-click="close_modal">Cancel</button><.button type="submit" phx-disable-with="Adding…">Add course</.button></div>
          </.form>
        </.modal>
      </.page>
    </Layouts.app>
    """
  end
end
