defmodule Bilimbi.People.Skills.Web.ActionsLive do
  @moduledoc "Development actions: propose from a gap, approve, progress, reassess and close."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.Access
  alias Bilimbi.People.Skills.Web.Support

  @capability "people.skills.actions.view"
  @propose_events ~w(create_action)
  @approve_events ~w(approve_action)
  @progress_events ~w(start_action hold_action complete_action cancel_action
                      link_action_reassessment)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Development actions")
     |> assign(:active_nav, "people.development.actions")
     |> assign(:companies, Support.companies(socket.assigns.current_scope.actor, @capability))
     |> assign(:group, :open)
     |> assign(:history, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.pick_company(socket.assigns.companies, params)
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_propose?: false}} = socket)
      when event in @propose_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_approve?: false}} = socket)
      when event in @approve_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_progress?: false}} = socket)
      when event in @progress_events,
      do: forbidden(socket)

  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/skills/actions?company_id=#{id}")}

  def handle_event("show_group", %{"group" => group}, socket),
    do:
      {:noreply,
       socket |> assign(:group, if(group == "closed", do: :closed, else: :open)) |> load()}

  def handle_event("show_history", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.actor

    case Skills.action_events(actor, socket.assigns.company.id, Support.to_integer(id)) do
      {:ok, events} ->
        {:noreply, assign(socket, :history, %{id: Support.to_integer(id), events: events})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Support.message(reason))}
    end
  end

  def handle_event("create_action", %{"action" => attrs}, socket) do
    act(
      socket,
      "Development action proposed.",
      fn actor, company_id ->
        Skills.propose_action(
          actor,
          company_id,
          attrs |> clean() |> Map.put("request_key", socket.assigns.request_key)
        )
      end,
      &assign(&1, :request_key, Support.new_key())
    )
  end

  def handle_event("approve_action", %{"id" => id}, socket) do
    act(socket, "Action approved.", fn actor, company_id ->
      Skills.approve_action(actor, company_id, Support.to_integer(id))
    end)
  end

  def handle_event("start_action", %{"id" => id}, socket) do
    act(socket, "Action started.", fn actor, company_id ->
      Skills.start_action(actor, company_id, Support.to_integer(id))
    end)
  end

  def handle_event("hold_action", %{"target" => id, "reason" => reason}, socket) do
    act(socket, "Action put on hold.", fn actor, company_id ->
      Skills.hold_action(actor, company_id, Support.to_integer(id), reason)
    end)
  end

  def handle_event("complete_action", %{"target" => id, "complete" => attrs}, socket) do
    act(socket, "Intervention recorded; a reassessment is now due.", fn actor, company_id ->
      Skills.complete_action(
        actor,
        company_id,
        Support.to_integer(id),
        attrs["evidence"],
        attrs["reassessment_due_on"]
      )
    end)
  end

  def handle_event("cancel_action", %{"target" => id, "reason" => reason}, socket) do
    act(socket, "Action cancelled.", fn actor, company_id ->
      Skills.cancel_action(actor, company_id, Support.to_integer(id), reason)
    end)
  end

  def handle_event(
        "link_action_reassessment",
        %{"target" => id, "assessment_id" => assessment_id},
        socket
      ) do
    act(socket, "Action closed against the reassessment.", fn actor, company_id ->
      Skills.link_action_reassessment(
        actor,
        company_id,
        Support.to_integer(id),
        Support.to_integer(assessment_id)
      )
    end)
  end

  defp clean(attrs), do: Support.blank_to_nil(attrs)

  defp forbidden(socket),
    do: {:noreply, put_flash(socket, :error, "You cannot do that for this company.")}

  defp act(socket, success, fun, on_ok \\ & &1) do
    actor = socket.assigns.current_scope.actor

    case socket.assigns.company do
      %{id: company_id} ->
        case fun.(actor, company_id) do
          {:ok, _} -> {:noreply, socket |> on_ok.() |> load() |> put_flash(:success, success)}
          {:error, reason} -> {:noreply, put_flash(socket, :error, Support.message(reason))}
        end

      nil ->
        forbidden(socket)
    end
  end

  defp load(%{assigns: %{company: nil}} = socket), do: assign_empty(socket)

  defp load(socket) do
    actor = socket.assigns.current_scope.actor
    company_id = socket.assigns.company.id
    can? = &Access.allowed?(actor, company_id, &1)
    can_propose? = can?.("people.skills.actions.manage")
    can_progress? = can_propose? or can?.("people.skills.actions.update")
    linked = Access.linked_employee_id(actor.scope, company_id, actor)

    with {:ok, actions} <- Skills.list_actions(actor, company_id, socket.assigns.group),
         {:ok, types} <- Skills.list_action_types(actor.scope, company_id) do
      assign(socket,
        available?: true,
        can_propose?: can_propose?,
        can_approve?: can?.("people.skills.actions.approve"),
        can_progress?: can_progress?,
        progressable:
          MapSet.new(
            for action <- actions,
                can_progress?,
                can_propose? or linked == {:ok, action.owner_employee_id},
                do: action.id
          ),
        actions: actions,
        types: Enum.filter(types, & &1.active),
        gaps: if(can_propose?, do: optional(Skills.gaps(actor, company_id), []), else: []),
        skills:
          if(can_propose?,
            do: optional(Skills.list_skills(actor.scope, company_id), []),
            else: []
          ),
        people:
          if(can_propose?, do: optional(Skills.action_people(actor, company_id), []), else: []),
        request_key: socket.assigns[:request_key] || Support.new_key()
      )
    else
      _ -> assign_empty(socket)
    end
  end

  defp optional({:ok, value}, _default), do: value
  defp optional(_other, default), do: default

  defp assign_empty(socket),
    do:
      assign(socket,
        available?: false,
        can_propose?: false,
        can_approve?: false,
        can_progress?: false,
        progressable: MapSet.new(),
        actions: [],
        types: [],
        gaps: [],
        skills: [],
        people: [],
        request_key: Support.new_key()
      )

  defp input_class, do: Support.input_class()
  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="actions-page">
        <.header>
          Development actions
          <:subtitle :if={@company}>{@company.name} · Closing skill gaps with owned, evidenced work</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="actions-no-company"
          title="No active company is available for development actions." />
        <form :if={@company} phx-change="select_company" id="actions-company-form">
          <label for="actions-company">Company</label>
          <select id="actions-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && not @available?} id="actions-unavailable"
          title="Development actions are unavailable while this company's workforce is not current." />

        <div :if={@available?} class="mt-5 space-y-5">
          <section class="rounded-xl border border-line bg-surface p-5">
            <div class="flex items-center gap-3">
              <h2 class="text-base font-semibold text-ink">Actions</h2>
              <span class="ml-auto flex gap-3 text-sm">
                <button type="button" class="underline" phx-click="show_group" phx-value-group="open">Open</button>
                <button type="button" class="underline" phx-click="show_group" phx-value-group="closed">Closed</button>
              </span>
            </div>
            <p :if={@actions == []} id="actions-empty" class="mt-3 text-sm text-ink-muted">
              No {if @group == :open, do: "open", else: "closed"} development actions.
            </p>
            <ul :if={@actions != []} id="actions" class="mt-3 divide-y divide-line text-sm">
              <li :for={action <- @actions} id={"action-#{action.id}"} class="py-3">
                <p>
                  <span class="font-medium">{action.employee_name}</span> · {action.skill_name} ·
                  {action.type_name} · level {action.starting_level} to {action.target_level} ·
                  <span id={"action-status-#{action.id}"}>{label(action.status)}</span>
                  <span :if={action.status == "completed"} class="text-ink-muted">
                    ({label(action.closure)}, now level {action.post_level})
                  </span>
                </p>
                <p class="text-ink-muted">{action.objective}</p>
                <p class="text-ink-muted">Owner {action.owner_name} · coordinator {action.coordinator_name} ·
                  {action.start_on} to {action.due_on} · {action.priority_explanation}</p>

                <div :if={action.id in @progressable or @can_approve?} class="mt-2 flex flex-wrap items-start gap-3">
                  <button :if={@can_approve? and action.status == "proposed"} type="button" class="underline"
                    phx-click="approve_action" phx-value-id={action.id}>Approve</button>
                  <button :if={action.id in @progressable and action.status in ~w(not_started scheduled on_hold)}
                    type="button" class="underline" phx-click="start_action" phx-value-id={action.id}>Start</button>
                  <form :if={action.id in @progressable and action.status in ~w(not_started scheduled in_progress)}
                    id={"hold-form-#{action.id}"} phx-submit="hold_action" class="flex items-center gap-2">
                    <input type="hidden" name="target" value={action.id} />
                    <input name="reason" required aria-label="Reason for hold" placeholder="Hold reason"
                      maxlength="2000" class={input_class()} />
                    <.button type="submit">Hold</.button>
                  </form>
                  <form :if={action.id in @progressable and action.status in ~w(not_started scheduled in_progress on_hold)}
                    id={"complete-form-#{action.id}"} phx-submit="complete_action"
                    class="flex flex-wrap items-center gap-2">
                    <input type="hidden" name="target" value={action.id} />
                    <input name="complete[evidence]" required aria-label="Completion evidence"
                      placeholder="Completion evidence" maxlength="2000" class={input_class()} />
                    <input name="complete[reassessment_due_on]" type="date" required
                      aria-label="Reassessment due" class={input_class()} />
                    <.button type="submit">Complete intervention</.button>
                  </form>
                  <form :if={action.id in @progressable and action.status == "pending_reassessment"}
                    id={"link-form-#{action.id}"} phx-submit="link_action_reassessment"
                    class="flex items-center gap-2">
                    <input type="hidden" name="target" value={action.id} />
                    <select name="assessment_id" aria-label="Finalized reassessment" class={input_class()}>
                      <option :for={row <- action.reassessments} value={row.id}>
                        {row.assessed_on} · level {row.assessed_level}
                      </option>
                    </select>
                    <.button type="submit">Close against reassessment</.button>
                  </form>
                  <form :if={action.id in @progressable and action.status not in ~w(completed cancelled)}
                    id={"cancel-form-#{action.id}"} phx-submit="cancel_action"
                    class="flex items-center gap-2">
                    <input type="hidden" name="target" value={action.id} />
                    <input name="reason" required aria-label="Reason for cancelling"
                      placeholder="Cancel reason" maxlength="2000" class={input_class()} />
                    <.button type="submit">Cancel</.button>
                  </form>
                </div>
                <button type="button" class="mt-1 underline" phx-click="show_history"
                  phx-value-id={action.id}>History</button>
                <ol :if={@history && @history.id == action.id} id={"action-history-#{action.id}"}
                  class="mt-1 space-y-1 text-ink-muted">
                  <li :for={event <- @history.events}>
                    {label(event.event_type)}{if event.to_status, do: " → #{label(event.to_status)}"}
                    {if event.comment, do: " · #{event.comment}"}
                  </li>
                </ol>
              </li>
            </ul>
          </section>

          <section :if={@can_propose?} class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Propose an action</h2>
            <p :if={@types == []} id="action-types-empty" class="mt-3 text-sm text-ink-muted">
              Add an action type under Skills policy before proposing an action.
            </p>
            <form :if={@types != [] and @people != []} id="action-form" phx-submit="create_action"
              class="mt-3 grid gap-2 sm:grid-cols-2">
              <select name="action[assessment_id]" aria-label="Assessment gap" class={input_class()}>
                <option value="">Manual (state the gap below)</option>
                <option :for={gap <- @gaps} value={gap.assessment_id}>
                  {gap.employee_name} · {gap.skill_name} · level {gap.current_level} of {gap.required_level}
                </option>
              </select>
              <select name="action[action_type_id]" aria-label="Action type" class={input_class()}>
                <option :for={type <- @types} value={type.id}>{type.name}</option>
              </select>
              <select name="action[employee_id]" aria-label="Employee (manual)" class={input_class()}>
                <option :for={person <- @people} value={person.id}>{person.name}</option>
              </select>
              <select name="action[skill_id]" aria-label="Skill (manual)" class={input_class()}>
                <option :for={skill <- @skills} :if={skill.active} value={skill.id}>{skill.name}</option>
              </select>
              <input name="action[starting_level]" type="number" min="0" max="20"
                aria-label="Starting level (manual)" placeholder="Starting level" class={input_class()} />
              <input name="action[target_level]" type="number" min="0" max="20"
                aria-label="Target level (manual)" placeholder="Target level" class={input_class()} />
              <select name="action[criticality]" aria-label="Criticality (manual)" class={input_class()}>
                <option :for={value <- ~w(critical essential development)} value={value}>{label(value)}</option>
              </select>
              <input name="action[manual_reason]" aria-label="Reason for a manual action"
                placeholder="Reason (manual only)" maxlength="1000" class={input_class()} />
              <input name="action[objective]" required aria-label="Objective" placeholder="Objective"
                maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <input name="action[intervention]" required aria-label="Intervention"
                placeholder="Intervention" maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <input name="action[expected_evidence]" required aria-label="Expected evidence"
                placeholder="Expected evidence" maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <select name="action[owner_employee_id]" aria-label="Owner" class={input_class()}>
                <option :for={person <- @people} value={person.id}>{person.name}</option>
              </select>
              <select name="action[coordinator_employee_id]" aria-label="Coordinator" class={input_class()}>
                <option :for={person <- @people} value={person.id}>{person.name}</option>
              </select>
              <select name="action[provider_employee_id]" aria-label="Trainer or coach" class={input_class()}>
                <option value="">No internal provider</option>
                <option :for={person <- @people} value={person.id}>{person.name}</option>
              </select>
              <input name="action[provider_name]" aria-label="External provider" placeholder="External provider"
                maxlength="160" class={input_class()} />
              <input name="action[start_on]" type="date" aria-label="Start" value={Date.utc_today()}
                class={input_class()} />
              <input name="action[due_on]" type="date" required aria-label="Due" class={input_class()} />
              <.button type="submit">Propose action</.button>
            </form>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
