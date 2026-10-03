defmodule Bilimbi.People.Skills.Web.PolicyLive do
  @moduledoc """
  Skills policy for one company: assessment and priority settings, development
  action types, and the reminder run.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.Access
  alias Bilimbi.People.Skills.Web.Support

  @capability "people.skills.policy.manage"
  @types_capability "people.skills.catalog.manage"
  @remind_capability "people.skills.reminders.send"

  @policy_events ~w(save_policy)
  @type_events ~w(create_action_type toggle_action_type)
  @remind_events ~w(run_reminders retry_reminders)

  @fields [
    reassessment_due_days: "Days a reassessment request stays open",
    default_reassessment_months: "Default months between assessments",
    reminder_window_days: "Days before validity ends to remind",
    backup_minimum: "Holders needed to cover a critical skill",
    multiplier_critical: "Critical priority multiplier",
    multiplier_essential: "Essential priority multiplier",
    multiplier_development: "Development priority multiplier"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Skills policy")
     |> assign(:active_nav, "people.settings.skills_policy")
     |> assign(:fields, @fields)
     |> assign(:companies, Support.companies(socket.assigns.current_scope.actor, @capability))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.pick_company(socket.assigns.companies, params)
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_policy?: false}} = socket)
      when event in @policy_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_types?: false}} = socket)
      when event in @type_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_remind?: false}} = socket)
      when event in @remind_events,
      do: forbidden(socket)

  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/skills/policy?company_id=#{id}")}

  def handle_event("save_policy", %{"policy" => values}, socket) do
    changes =
      for {name, _label} <- @fields, into: %{} do
        {name, Support.to_integer(Map.get(values, Atom.to_string(name)))}
      end

    act(socket, "Skills policy saved.", fn _actor, scope, company_id ->
      Skills.put_policy(scope, company_id, changes)
    end)
  end

  def handle_event("create_action_type", %{"type" => attrs}, socket) do
    attrs = Map.put(attrs, "requires_provider", Map.get(attrs, "requires_provider") == "true")

    act(socket, "Action type added.", fn _actor, scope, company_id ->
      Skills.create_action_type(scope, company_id, attrs)
    end)
  end

  def handle_event("toggle_action_type", %{"id" => id, "active" => active}, socket) do
    act(socket, "Action type updated.", fn _actor, scope, company_id ->
      Skills.set_action_type_active(scope, company_id, Support.to_integer(id), active == "true")
    end)
  end

  def handle_event("run_reminders", _params, socket) do
    act(socket, "Reminders queued.", fn _actor, scope, company_id ->
      with :ok <- Skills.enqueue_reminders(scope, company_id), do: {:ok, :queued}
    end)
  end

  def handle_event("retry_reminders", _params, socket) do
    act(socket, "Failed reminders retried.", fn actor, _scope, company_id ->
      Skills.retry_reminders(actor, company_id)
    end)
  end

  defp forbidden(socket),
    do: {:noreply, put_flash(socket, :error, "You cannot change this company's skills policy.")}

  # The `can_*?` assigns only decide which controls render; the facade
  # authorizes each write for the scope's actor when it runs, so a grant
  # revoked while the page is open refuses the next event and the page reloads
  # its controls.
  defp act(socket, success, fun) do
    actor = socket.assigns.current_scope.actor

    case socket.assigns.company do
      %{id: company_id} ->
        case fun.(actor, socket.assigns.current_scope.scope, company_id) do
          {:ok, _} ->
            {:noreply, socket |> load() |> put_flash(:success, success)}

          {:error, :unauthorized} ->
            {:noreply,
             socket
             |> load()
             |> put_flash(
               :error,
               "You no longer have permission to change this company's skills policy."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Support.message(reason))}
        end

      nil ->
        forbidden(socket)
    end
  end

  defp load(%{assigns: %{company: nil}} = socket), do: assign_empty(socket)

  defp load(socket) do
    actor = socket.assigns.current_scope.actor
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    with {:ok, policy} <- Skills.policy(scope, company_id),
         {:ok, types} <- Skills.list_action_types(scope, company_id) do
      can_remind? = Access.allowed?(actor, company_id, @remind_capability)

      assign(socket,
        available?: true,
        can_policy?: Access.allowed?(actor, company_id, @capability),
        can_types?: Access.allowed?(actor, company_id, @types_capability),
        can_remind?: can_remind?,
        policy: policy,
        types: types,
        due:
          if(can_remind?,
            do:
              case Skills.due_reminders(actor, company_id) do
                {:ok, due} -> due
                _ -> []
              end,
            else: []
          )
      )
    else
      _ -> assign_empty(socket)
    end
  end

  defp assign_empty(socket),
    do:
      assign(socket,
        available?: false,
        can_policy?: false,
        can_types?: false,
        can_remind?: false,
        policy: %{},
        types: [],
        due: []
      )

  defp input_class, do: Support.input_class()
  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="skills-policy-page">
        <.header>
          Skills policy
          <:subtitle :if={@company}>{@company.name} · Assessment, priority and reminder settings</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="skills-policy-no-company"
          title="No active company is available for skills policy." />
        <form :if={@company} phx-change="select_company" id="skills-policy-company-form">
          <label for="skills-policy-company">Company</label>
          <select id="skills-policy-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && not @available?} id="skills-policy-unavailable"
          title="Skills policy is unavailable while this company's workforce is not current." />

        <div :if={@available?} class="mt-5 grid gap-5 lg:grid-cols-2">
          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Policy</h2>
            <form id="skills-policy-form" phx-submit="save_policy" class="mt-3 space-y-2">
              <label :for={{name, text} <- @fields} class="flex items-center gap-2 text-sm">
                <span class="flex-1">{text}</span>
                <input name={"policy[#{name}]"} type="number" min="0" max="365" required
                  value={Map.get(@policy, name)} disabled={not @can_policy?} class={input_class()} />
              </label>
              <.button :if={@can_policy?} type="submit">Save policy</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Development action types</h2>
            <p :if={@types == []} id="action-types-none" class="mt-3 text-sm text-ink-muted">
              No action types yet. Actions cannot be proposed until one is added.
            </p>
            <ul :if={@types != []} id="action-types" class="mt-3 divide-y divide-line text-sm">
              <li :for={type <- @types} id={"action-type-#{type.id}"} class="flex items-center gap-2 py-2">
                <span class="font-medium">{type.name}</span>
                <span class="text-ink-muted">{type.code}{if type.requires_provider, do: " · needs a provider"}</span>
                <span :if={not type.active} class="text-ink-muted">· inactive</span>
                <button :if={@can_types?} type="button" class="ml-auto underline" phx-click="toggle_action_type"
                  phx-value-id={type.id} phx-value-active={to_string(not type.active)}>
                  {if type.active, do: "Deactivate", else: "Reactivate"}
                </button>
              </li>
            </ul>
            <form :if={@can_types?} id="action-type-form" phx-submit="create_action_type"
              class="mt-3 grid gap-2 sm:grid-cols-2">
              <input name="type[code]" required aria-label="Type code" placeholder="Code" maxlength="80"
                class={input_class()} />
              <input name="type[name]" required aria-label="Type name" placeholder="Name" maxlength="160"
                class={input_class()} />
              <label class="flex items-center gap-2 text-sm">
                <input type="checkbox" name="type[requires_provider]" value="true" />Needs a trainer or provider
              </label>
              <.button type="submit">Add type</.button>
            </form>
          </section>

          <section :if={@can_remind?} class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Reminders</h2>
            <p :if={@due == []} id="reminders-none" class="mt-3 text-sm text-ink-muted">
              Nothing is due today.
            </p>
            <ul :if={@due != []} id="reminders-due" class="mt-3 text-sm">
              <li :for={item <- @due}>
                {label(item.rule)} · due {item.due_on} ·
                {if item.recipients == [], do: "no one to tell", else: "#{length(item.recipients)} to tell"}
              </li>
            </ul>
            <div class="mt-3 flex gap-3">
              <.button type="button" phx-click="run_reminders">Send due reminders</.button>
              <.button type="button" phx-click="retry_reminders">Retry failed reminders</.button>
            </div>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
