defmodule Bilimbi.People.Skills.Web.MySkillsLive do
  @moduledoc "The signed-in employee's own skill standing, actions and reminders."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.Web.Support

  @capability "people.skills.self.view"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "My skills")
     |> assign(:active_nav, "people.my_work.skills")
     |> assign(:companies, Support.companies(socket.assigns.current_scope.scope, @capability))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.pick_company(socket.assigns.companies, params)
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/skills/my?company_id=#{id}")}

  defp load(%{assigns: %{company: nil}} = socket), do: assign(socket, standing: nil, inbox: [])

  defp load(socket) do
    actor = socket.assigns.current_scope.actor
    company_id = socket.assigns.company.id

    case Skills.standing(actor, company_id) do
      {:ok, standing} ->
        inbox =
          case Skills.reminder_inbox(actor, company_id) do
            {:ok, rows} -> rows
            _ -> []
          end

        assign(socket, standing: standing, inbox: inbox)

      _ ->
        assign(socket, standing: nil, inbox: [])
    end
  end

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="my-skills-page">
        <.header>
          My skills
          <:subtitle :if={@company}>{@company.name} · Your assessed levels against your requirements</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="my-skills-no-company"
          title="No active company is available for skills." />
        <form :if={@company} phx-change="select_company" id="my-skills-company-form">
          <label for="my-skills-company">Company</label>
          <select id="my-skills-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && @standing == nil} id="my-skills-unavailable"
          title="Your skills are unavailable: your account needs a link to a current employee." />

        <div :if={@standing} class="mt-5 space-y-5">
          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Assessed skills</h2>
            <p :if={@standing.scores == []} id="my-skills-empty" class="mt-3 text-sm text-ink-muted">
              No assessment of yours has been finalized yet.
            </p>
            <.table :if={@standing.scores != []} id="my-skills" rows={@standing.scores}
              row_id={&"my-skill-#{&1.skill_id}"}>
              <:col :let={row} label="Skill">{row.skill_name}</:col>
              <:col :let={row} label="Level" align={:right}>{row.current_level} / {row.required_level}</:col>
              <:col :let={row} label="Result">{label(row.result_band)}</:col>
              <:col :let={row} label="Assessed">{row.assessed_on}</:col>
              <:col :let={row} label="Next due">{row.next_due_on}</:col>
              <:col :let={row} label="State">{label(row.state)}</:col>
            </.table>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Development actions</h2>
            <p :if={@standing.actions == []} id="my-actions-empty" class="mt-3 text-sm text-ink-muted">
              No development action has been approved for you.
            </p>
            <ul :if={@standing.actions != []} id="my-actions" class="mt-3 divide-y divide-line text-sm">
              <li :for={action <- @standing.actions} id={"my-action-#{action.id}"} class="py-2">
                <span class="font-medium">{action.skill_name}</span> · level {action.starting_level} to
                {action.target_level} · {label(action.status)} · due {action.due_on}
                <span class="block text-ink-muted">{action.objective}</span>
              </li>
            </ul>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Reassessments and reminders</h2>
            <p :if={@standing.reassessments == [] and @inbox == []} id="my-reminders-empty"
              class="mt-3 text-sm text-ink-muted">
              Nothing is waiting for you.
            </p>
            <ul id="my-reassessments" class="mt-3 text-sm">
              <li :for={request <- @standing.reassessments} id={"my-reassessment-#{request.id}"}>
                {request.skill_name} will be reassessed by {request.due_on}.
              </li>
            </ul>
            <ul :if={@inbox != []} id="my-reminders" class="mt-3 text-sm">
              <li :for={reminder <- @inbox} id={"my-reminder-#{reminder.id}"}>
                {label(reminder.rule)} · {reminder.due_on}
              </li>
            </ul>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
