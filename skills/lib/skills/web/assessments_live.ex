defmodule Bilimbi.People.Skills.Web.AssessmentsLive do
  @moduledoc """
  Skill assessments: the submit form, the review and finalization queue, the
  register, reassessment requests, team gaps and critical-skill coverage.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.Access
  alias Bilimbi.People.Skills.Web.Support

  @capability "people.skills.assessments.view"

  @submit_events ~w(create_assessment)
  @review_events ~w(review_assessment return_assessment)
  @finalize_events ~w(finalize_assessment)
  @request_events ~w(create_reassessment_request)
  @perform_events ~w(perform_reassessment)
  @cancel_events ~w(cancel_reassessment)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Assessments")
     |> assign(:active_nav, "people.development.assessments")
     |> assign(:companies, Support.companies(socket.assigns.current_scope.scope, @capability))
     |> assign(:status_filter, "")
     |> assign(:correcting, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company = Support.pick_company(socket.assigns.companies, params)
    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_submit?: false}} = socket)
      when event in @submit_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_review?: false}} = socket)
      when event in @review_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_finalize?: false}} = socket)
      when event in @finalize_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_request?: false}} = socket)
      when event in @request_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_perform?: false}} = socket)
      when event in @perform_events,
      do: forbidden(socket)

  def handle_event(event, _params, %{assigns: %{can_cancel?: false}} = socket)
      when event in @cancel_events,
      do: forbidden(socket)

  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/skills/assessments?company_id=#{id}")}

  def handle_event("filter_register", %{"status" => status}, socket),
    do: {:noreply, socket |> assign(:status_filter, status) |> load()}

  def handle_event("start_correction", %{"id" => id}, socket) do
    correcting = Enum.find(socket.assigns.queue.returned, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :correcting, correcting)}
  end

  def handle_event("create_assessment", %{"assessment" => attrs}, socket) do
    act(
      socket,
      "Assessment submitted for review.",
      fn actor, company_id ->
        Skills.submit_assessment(actor, company_id, Support.blank_to_nil(attrs))
      end,
      &assign(&1, correcting: nil, request_key: Support.new_key())
    )
  end

  def handle_event("review_assessment", %{"id" => id}, socket) do
    act(socket, "Assessment verified.", fn actor, company_id ->
      Skills.review_assessment(actor, company_id, Support.to_integer(id), :verify, nil)
    end)
  end

  def handle_event("return_assessment", %{"target" => id, "note" => note}, socket) do
    act(socket, "Assessment returned to the assessor.", fn actor, company_id ->
      Skills.review_assessment(actor, company_id, Support.to_integer(id), :return, note)
    end)
  end

  def handle_event("finalize_assessment", %{"id" => id}, socket) do
    act(socket, "Assessment finalized; the current score is updated.", fn actor, company_id ->
      Skills.finalize_assessment(actor, company_id, Support.to_integer(id))
    end)
  end

  def handle_event("create_reassessment_request", %{"request" => attrs}, socket) do
    act(socket, "Reassessment requested.", fn actor, company_id ->
      Skills.request_reassessment(
        actor,
        company_id,
        attrs["employee_id"],
        attrs["skill_id"],
        attrs["reason"]
      )
    end)
  end

  def handle_event("perform_reassessment", %{"perform" => attrs}, socket) do
    act(socket, "Reassessment submitted for review.", fn actor, company_id ->
      Skills.perform_reassessment(
        actor,
        company_id,
        Support.to_integer(attrs["request_id"]),
        attrs |> Map.delete("request_id") |> Support.blank_to_nil()
      )
    end)
  end

  def handle_event("cancel_reassessment", %{"id" => id}, socket) do
    act(socket, "Reassessment request cancelled.", fn actor, company_id ->
      Skills.cancel_reassessment(actor, company_id, Support.to_integer(id))
    end)
  end

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
    filters = %{status: socket.assigns.status_filter}

    with {:ok, queue} <- Skills.assessment_queue(actor, company_id),
         {:ok, register} <- Skills.list_assessments(actor, company_id, filters),
         {:ok, gaps} <- Skills.gaps(actor, company_id),
         {:ok, skills} <- Skills.list_skills(actor.scope, company_id) do
      can_request? = can?.("people.skills.reassessments.submit")
      can_perform? = can?.("people.skills.reassessments.execute")

      assign(socket,
        available?: true,
        can_submit?: can?.("people.skills.assessments.submit"),
        can_review?: can?.("people.skills.assessments.review"),
        can_finalize?: can?.("people.skills.assessments.approve"),
        can_request?: can_request?,
        can_perform?: can_perform?,
        can_cancel?: can_request? or can_perform?,
        queue: queue,
        register: register,
        gaps: gaps,
        skills: Enum.filter(skills, & &1.active),
        employees: optional(Skills.assessable_employees(actor, company_id), []),
        reassessments: optional(Skills.pending_reassessments(actor, company_id), []),
        coverage: optional(Skills.coverage(actor, company_id), nil),
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
        can_submit?: false,
        can_review?: false,
        can_finalize?: false,
        can_request?: false,
        can_perform?: false,
        can_cancel?: false,
        queue: %{review: [], finalize: [], returned: []},
        register: [],
        gaps: [],
        skills: [],
        employees: [],
        reassessments: [],
        coverage: nil,
        request_key: Support.new_key()
      )

  defp input_class, do: Support.input_class()

  defp queue_empty?(queue),
    do: queue.review == [] and queue.finalize == [] and queue.returned == []

  defp band(band), do: band |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="assessments-page">
        <.header>
          Assessments
          <:subtitle :if={@company}>{@company.name} · Evidence-backed skill assessments and reassessment</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="assessments-no-company"
          title="No active company is available for assessments." />
        <form :if={@company} phx-change="select_company" id="assessments-company-form">
          <label for="assessments-company">Company</label>
          <select id="assessments-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && not @available?} id="assessments-unavailable"
          title="Assessments are unavailable while this company's workforce is not current." />

        <div :if={@available?} class="mt-5 grid gap-5 lg:grid-cols-2">
          <section id="assessment-queue-section" class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Waiting on you</h2>
            <p :if={queue_empty?(@queue)} id="assessment-queue-empty" class="mt-3 text-sm text-ink-muted">
              Nothing is waiting for your review, finalization or correction.
            </p>
            <div :if={@queue.review != []} id="assessment-review-queue" class="mt-3">
              <h3 class="text-sm font-medium">To review</h3>
              <ul class="divide-y divide-line text-sm">
                <li :for={row <- @queue.review} id={"review-#{row.id}"} class="py-2">
                  <p><span class="font-medium">{row.employee_name}</span> · {row.skill_name} ·
                    level {row.assessed_level} of {row.required_level} required ·
                    {band(row.result_band)} · {row.assessed_on}</p>
                  <p class="text-ink-muted">Evidence: {row.evidence}</p>
                  <div :if={@can_review?} class="mt-1 flex flex-wrap items-center gap-3">
                    <button type="button" class="underline" phx-click="review_assessment"
                      phx-value-id={row.id}>Verify</button>
                    <form id={"return-form-#{row.id}"} phx-submit="return_assessment"
                      class="flex items-center gap-2">
                      <input type="hidden" name="target" value={row.id} />
                      <input name="note" aria-label="Reason for returning" placeholder="Reason" required
                        maxlength="2000" class={input_class()} />
                      <.button type="submit">Return</.button>
                    </form>
                  </div>
                </li>
              </ul>
            </div>
            <div :if={@queue.finalize != []} id="assessment-finalize-queue" class="mt-3">
              <h3 class="text-sm font-medium">To finalize</h3>
              <ul class="divide-y divide-line text-sm">
                <li :for={row <- @queue.finalize} id={"finalize-#{row.id}"} class="flex items-center gap-3 py-2">
                  <span><span class="font-medium">{row.employee_name}</span> · {row.skill_name} ·
                    level {row.assessed_level}</span>
                  <button :if={@can_finalize?} type="button" class="ml-auto underline"
                    phx-click="finalize_assessment" phx-value-id={row.id}>Finalize</button>
                </li>
              </ul>
            </div>
            <div :if={@queue.returned != []} id="assessment-returned-queue" class="mt-3">
              <h3 class="text-sm font-medium">Returned to you</h3>
              <ul class="divide-y divide-line text-sm">
                <li :for={row <- @queue.returned} id={"returned-#{row.id}"} class="flex items-center gap-3 py-2">
                  <span><span class="font-medium">{row.employee_name}</span> · {row.skill_name} ·
                    {row.review_note}</span>
                  <button :if={@can_submit?} type="button" class="ml-auto underline"
                    phx-click="start_correction" phx-value-id={row.id}>Correct</button>
                </li>
              </ul>
            </div>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Assess an employee</h2>
            <p :if={not @can_submit?} id="assessment-form-denied" class="mt-3 text-sm text-ink-muted">
              You do not assess employees for this company.
            </p>
            <p :if={@can_submit? and @employees == []} id="assessment-employees-empty"
              class="mt-3 text-sm text-ink-muted">
              No employee is within your reach to assess.
            </p>
            <form :if={@can_submit? and @employees != [] and @skills != []} id="assessment-form"
              phx-submit="create_assessment" class="mt-3 grid gap-2 sm:grid-cols-2">
              <input type="hidden" name="assessment[request_key]" value={@request_key} />
              <input :if={@correcting} type="hidden" name="assessment[supersedes_assessment_id]"
                value={@correcting.id} />
              <select name="assessment[employee_id]" aria-label="Employee" class={input_class()}>
                <option :for={employee <- @employees} value={employee.id}
                  selected={@correcting && @correcting.employee_id == employee.id}>{employee.name}</option>
              </select>
              <select name="assessment[skill_id]" aria-label="Skill" class={input_class()}>
                <option :for={skill <- @skills} value={skill.id}
                  selected={@correcting && @correcting.skill_id == skill.id}>{skill.name}</option>
              </select>
              <input name="assessment[assessed_level]" type="number" min="0" max="20" required
                aria-label="Assessed level" placeholder="Assessed level" class={input_class()} />
              <input name="assessment[assessed_on]" type="date" aria-label="Assessed on"
                value={Date.utc_today()} class={input_class()} />
              <textarea name="assessment[evidence]" aria-label="Evidence" placeholder="Evidence" required
                maxlength="4000" class={[input_class(), "sm:col-span-2"]}></textarea>
              <input name="assessment[method]" aria-label="Method" placeholder="Method (optional)"
                maxlength="80" class={input_class()} />
              <input name="assessment[valid_until]" type="date" aria-label="Valid until"
                class={input_class()} />
              <input name="assessment[notes]" aria-label="Notes" placeholder="Notes (optional)"
                maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <.button type="submit">{if @correcting, do: "Submit correction", else: "Submit for review"}</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Reassessment requests</h2>
            <p :if={@reassessments == []} id="reassessment-empty" class="mt-3 text-sm text-ink-muted">
              No reassessment is waiting.
            </p>
            <ul :if={@reassessments != []} id="reassessment-requests" class="mt-3 divide-y divide-line text-sm">
              <li :for={request <- @reassessments} id={"reassessment-#{request.id}"} class="py-2">
                <p><span class="font-medium">{request.employee_name}</span> · {request.skill_name} ·
                  due {request.due_on}</p>
                <p class="text-ink-muted">{request.reason}</p>
                <form :if={@can_perform?} id={"perform-form-#{request.id}"} phx-submit="perform_reassessment"
                  class="mt-1 grid gap-2 sm:grid-cols-3">
                  <input type="hidden" name="perform[request_id]" value={request.id} />
                  <input name="perform[assessed_level]" type="number" min="0" max="20" required
                    aria-label="Reassessed level" placeholder="Level" class={input_class()} />
                  <input name="perform[evidence]" required aria-label="Reassessment evidence"
                    placeholder="Evidence" maxlength="4000" class={input_class()} />
                  <.button type="submit">Perform</.button>
                </form>
                <button :if={@can_cancel?} type="button" class="mt-1 underline" phx-click="cancel_reassessment"
                  phx-value-id={request.id}>Cancel request</button>
              </li>
            </ul>
            <form :if={@can_request? and @employees != [] and @skills != []} id="reassessment-form"
              phx-submit="create_reassessment_request" class="mt-3 grid gap-2 sm:grid-cols-2">
              <select name="request[employee_id]" aria-label="Employee" class={input_class()}>
                <option :for={employee <- @employees} value={employee.id}>{employee.name}</option>
              </select>
              <select name="request[skill_id]" aria-label="Skill" class={input_class()}>
                <option :for={skill <- @skills} value={skill.id}>{skill.name}</option>
              </select>
              <input name="request[reason]" required aria-label="Reason" placeholder="Reason"
                maxlength="1000" class={[input_class(), "sm:col-span-2"]} />
              <.button type="submit">Request reassessment</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <div class="flex items-center gap-3">
              <h2 class="text-base font-semibold text-ink">Register</h2>
              <form id="register-filter" phx-change="filter_register" class="ml-auto">
                <select name="status" aria-label="Status" class={input_class()}>
                  <option value="" selected={@status_filter == ""}>All</option>
                  <option :for={status <- ~w(pending_review verified returned finalized)} value={status}
                    selected={@status_filter == status}>{band(status)}</option>
                </select>
              </form>
            </div>
            <p :if={@register == []} id="assessment-register-empty" class="mt-3 text-sm text-ink-muted">
              No assessments have been recorded within your reach.
            </p>
            <.table :if={@register != []} id="assessment-register" rows={@register}
              row_id={&"assessment-#{&1.id}"}>
              <:col :let={row} label="Employee">{row.employee_name}</:col>
              <:col :let={row} label="Skill">{row.skill_name}</:col>
              <:col :let={row} label="Level" align={:right}>{row.assessed_level} / {row.required_level}</:col>
              <:col :let={row} label="Result">{band(row.result_band)}</:col>
              <:col :let={row} label="Assessed">{row.assessed_on}</:col>
              <:col :let={row} label="Next due">{row.next_due_on}</:col>
              <:col :let={row} label="Status">{band(row.status)}</:col>
            </.table>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Gaps</h2>
            <p :if={@gaps == []} id="team-gaps-empty" class="mt-3 text-sm text-ink-muted">
              No current skill gaps within your reach.
            </p>
            <.table :if={@gaps != []} id="team-gaps" rows={@gaps}
              row_id={&"gap-#{&1.employee_id}-#{&1.skill_id}"}>
              <:col :let={row} label="Employee">{row.employee_name}</:col>
              <:col :let={row} label="Skill">{row.skill_name}</:col>
              <:col :let={row} label="Level" align={:right}>{row.current_level} / {row.required_level}</:col>
              <:col :let={row} label="Priority" align={:right}>{row.priority_score}</:col>
              <:col :let={row} label="Mandatory">{if row.mandatory, do: "Yes", else: "No"}</:col>
              <:col :let={row} label="State">{band(to_string(row.state))}</:col>
            </.table>
          </section>

          <section :if={@coverage} class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Critical-skill coverage</h2>
            <p :if={@coverage == []} id="coverage-empty" class="mt-3 text-sm text-ink-muted">
              No skill is marked critical for this company.
            </p>
            <.table :if={@coverage != []} id="coverage" rows={@coverage} row_id={&"coverage-#{&1.skill_id}"}>
              <:col :let={row} label="Skill">{row.name}</:col>
              <:col :let={row} label="Holders" align={:right}>{row.holders}</:col>
              <:col :let={row} label="Minimum" align={:right}>{row.minimum}</:col>
              <:col :let={row} label="Covered">{if row.covered, do: "Yes", else: "No"}</:col>
            </.table>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
