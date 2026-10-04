defmodule Bilimbi.People.Attendance.Web.ShiftsLive do
  @moduledoc "Operator-managed shift templates for one company."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.ShiftTemplate
  alias Bilimbi.People.Attendance.Web.Components, as: AttendanceComponents
  @capability "people.attendance.rules.manage"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Shift templates")
     |> assign(:active_nav, "people.attendance.rules")
     |> assign(
       :companies,
       AttendanceComponents.companies(socket.assigns.current_scope.scope, @capability)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = AttendanceComponents.pick(socket.assigns.companies, params["company_id"])
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/attendance/rules/shifts?company_id=#{id}")}

  def handle_event(_event, _params, %{assigns: %{company: nil}} = socket), do: {:noreply, socket}

  def handle_event("create", %{"shift" => attrs}, socket) do
    case Attendance.create_shift_template(scope(socket), socket.assigns.company.id, attrs) do
      {:ok, _template} ->
        {:noreply, socket |> load() |> put_flash(:success, "Shift template added.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_message(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, refusal(:unauthorized))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Shift templates are unavailable for this company.")}
    end
  end

  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, _} <-
           Attendance.set_shift_template_status(
             scope(socket),
             socket.assigns.company.id,
             id,
             status
           ) do
      {:noreply, socket |> load() |> put_flash(:success, "Shift template updated.")}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, refusal(:unauthorized))}
      _ -> {:noreply, put_flash(socket, :error, "Shift template could not be updated.")}
    end
  end

  defp refusal(:unauthorized),
    do: "You no longer have permission to change this company's shift templates."

  defp error_message(changeset) do
    cond do
      Keyword.has_key?(changeset.errors, :company_id) ->
        "That code is already used by another shift template."

      Keyword.has_key?(changeset.errors, :ends_at) ->
        "The shift must end at a different time than it starts."

      changeset.errors[:break_minutes] == {"must be shorter than the shift", []} ->
        "The break must be shorter than the shift."

      Keyword.has_key?(changeset.errors, :break_minutes) ->
        "Enter break minutes of 0 or more."

      true ->
        "Enter a code, a name, and start and end times."
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp load(%{assigns: %{company: nil}} = socket), do: assign(socket, :templates, nil)

  defp load(socket) do
    templates =
      case Attendance.list_shift_templates(scope(socket), socket.assigns.company.id) do
        {:ok, values} -> values
        _ -> nil
      end

    assign(socket, :templates, templates)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, AttendanceComponents.input_class())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="attendance-shifts-page" variant={:form}>
        <.header>
          Attendance rules
          <:subtitle>Shift templates planners assign on the roster.</:subtitle>
        </.header>
        <AttendanceComponents.rules_tabs current={:shifts} company={@company} actor={@current_scope.actor} />
        <.empty_state :if={@company == nil} id="attendance-shifts-no-company" class="mt-5"
          title="No active company is available for shift templates." />
        <div :if={@company} class="mt-5 space-y-5">
          <AttendanceComponents.company_select id="attendance-shifts-company" companies={@companies} company={@company} />
          <.empty_state :if={@templates == nil} id="attendance-shifts-unavailable"
            title="Shift templates are unavailable for this company."
            reason="The company's workforce is not current." />
          <.card :if={@templates} inner_class="p-5 sm:p-6" role="region" aria-labelledby="attendance-shifts-heading">
            <.section_heading id="attendance-shifts-heading" title="Shift templates" />
            <p :if={@templates == []} id="attendance-shifts-empty" class="mt-2 text-sm text-ink-muted">
              No shift templates have been added for this company.
            </p>
            <ul :if={@templates != []} class="mt-3 divide-y divide-line text-sm">
              <li :for={template <- @templates} id={"shift-template-#{template.id}"} class="flex flex-wrap items-center gap-3 py-1.5">
                <span class="font-medium">{template.name}</span>
                <span class="text-ink-muted">{template.code}</span>
                <span class="text-ink-muted">{AttendanceComponents.shift_hours(template)}</span>
                <span class="text-ink-muted">{ShiftTemplate.span_minutes(template)} min, break {template.break_minutes} min</span>
                <.badge kind={if template.status == "active", do: :success, else: :neutral}>{template.status}</.badge>
                <button type="button" phx-click="set_status" phx-value-id={template.id}
                  phx-value-status={if template.status == "active", do: "retired", else: "active"}
                  class="text-link hover:underline">
                  {if template.status == "active", do: "Retire", else: "Reactivate"}
                </button>
              </li>
            </ul>
            <form id="attendance-shift-form" phx-submit="create" class="mt-4 grid gap-2 sm:grid-cols-2">
              <input name="shift[code]" aria-label="Shift code" placeholder="Code" required maxlength="40" class={@input} />
              <input name="shift[name]" aria-label="Shift name" placeholder="Name" required maxlength="120" class={@input} />
              <label class="text-sm text-ink">Starts
                <input name="shift[starts_at]" type="time" required class={["ml-2", @input]} />
              </label>
              <label class="text-sm text-ink">Ends
                <input name="shift[ends_at]" type="time" required class={["ml-2", @input]} />
              </label>
              <label class="text-sm text-ink">Break minutes
                <input name="shift[break_minutes]" type="number" min="0" value="0" class={["ml-2 w-24", @input]} />
              </label>
              <div><.button type="submit">Add shift template</.button></div>
            </form>
            <p class="mt-2 text-xs text-ink-muted">An end at or before the start crosses midnight.</p>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
