defmodule Bilimbi.People.Training.Web.LearningLive do
  @moduledoc "Governed learning requests, own evaluations, plans and company budget policy."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.Passport
  alias Bilimbi.People.Training.Web.Support
  @write_events ~w(open_entry add_item save_entry decide confirm_decision save_currencies)
  @evaluation_events ~w(open_evaluation save_evaluation confirm_evaluation)
  @destinations [
    {"My learning", "/people/training/my", "people.training.learning.view"},
    {"Team requests", "/people/training/team", "people.training.requests.recommend"},
    {"Team plans", "/people/training/plans", "people.training.plans.submit"},
    {"Learning requests & reviews", "/people/training/requests", "people.training.requests.view"},
    {"Plan reviews", "/people/training/plan-reviews", "people.training.plans.view"},
    {"Learning policy and budgets", "/people/training/budgets", "people.training.budgets.view"}
  ]
  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       modal: false,
       pending_decision: nil,
       prior_id: nil,
       item_count: 1,
       form: to_form(%{}, as: :entry),
       decision_form: to_form(%{}, as: :decision),
       selected_evaluation: nil,
       pending_evaluation: nil,
       evaluation_form: to_form(%{}, as: :evaluation)
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    # The host consumes its generated live_action for route authorization.
    # The authorized URI identifies the task without relying on that cleared assign.
    path = URI.parse(uri).path
    {title, _, cap} = Enum.find(@destinations, fn {_, p, _} -> p == path end)

    {kind, audience} =
      case path do
        "/people/training/my" -> {:request, :self}
        "/people/training/team" -> {:request, :team}
        "/people/training/plans" -> {:plan, :team}
        "/people/training/requests" -> {:request, :hr}
        "/people/training/plan-reviews" -> {:plan, :hr}
        _ -> {:budget, :hr}
      end

    companies = Support.companies(socket.assigns.current_scope, cap)

    {:noreply,
     socket
     |> assign(
       page_title: title,
       active_nav:
         case path do
           "/people/training/my" -> "people.my_work.my_learning"
           "/people/training/budgets" -> "people.settings.learning_policy"
           _ -> "people.development.learning_reviews"
         end,
       path: path,
       kind: kind,
       audience: audience,
       companies: companies,
       company: Support.company(companies, params),
       params: params,
       modal: false,
       pending_decision: nil,
       selected_evaluation: nil,
       pending_evaluation: nil
     )
     |> load()}
  end

  @impl true
  def handle_event(event, _, %{assigns: %{can_write?: false}} = socket)
      when event in @write_events,
      do:
        {:noreply,
         put_flash(socket, :error, "You cannot change this company's learning records.")}

  def handle_event(event, _, %{assigns: %{can_evaluate?: false}} = socket)
      when event in @evaluation_events,
      do: {:noreply, put_flash(socket, :error, "You cannot answer this company's evaluations.")}

  def handle_event("select_company", %{"filters" => attrs}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           socket.assigns.path <>
             "?" <>
             URI.encode_query(Map.merge(socket.assigns.params, attrs) |> Map.put("page", "1"))
       )}

  def handle_event("page", %{"page" => page}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           socket.assigns.path <>
             "?" <> URI.encode_query(Map.put(socket.assigns.params, "page", page))
       )}

  def handle_event("open_entry", params, socket) do
    prior = Support.integer(params["prior_id"] || "")

    {:noreply,
     socket
     |> clear_flash()
     |> assign(modal: true, prior_id: prior, item_count: 1, form: to_form(%{}, as: :entry))}
  end

  def handle_event("add_item", _, socket),
    do: {:noreply, assign(socket, item_count: min(socket.assigns.item_count + 1, 300))}

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: false)}

  def handle_event("save_entry", %{"entry" => attrs} = params, socket) do
    a = socket.assigns
    scope = a.current_scope.scope

    items =
      (params["items"] || %{})
      |> Enum.sort_by(fn {k, _} -> Support.integer(k) || 0 end)
      |> Enum.map(&elem(&1, 1))

    result =
      case a.kind do
        :request ->
          Training.create_learning_request(scope, a.company.id, attrs)

        :budget ->
          if a.prior_id,
            do: Training.supersede_budget_policy(scope, a.company.id, a.prior_id, attrs),
            else: Training.create_budget_policy(scope, a.company.id, attrs)

        :plan ->
          if a.prior_id,
            do: Training.amend_learning_plan(scope, a.company.id, a.prior_id, attrs, items),
            else: Training.create_learning_plan(scope, a.company.id, attrs, items)
      end

    finish(socket, result, "Learning record created.", attrs)
  end

  def handle_event("decide", %{"decision" => attrs}, socket),
    do: {:noreply, assign(socket, pending_decision: attrs)}

  def handle_event("cancel_decision", _, socket),
    do: {:noreply, assign(socket, pending_decision: nil)}

  def handle_event("confirm_decision", _, %{assigns: %{pending_decision: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_decision", _, socket) do
    attrs = socket.assigns.pending_decision
    socket = assign(socket, pending_decision: nil)
    a = socket.assigns
    id = Support.integer(attrs["id"])

    result =
      case a.kind do
        :request ->
          Training.decide_learning_request(
            a.current_scope.scope,
            a.company.id,
            id,
            attrs["action"],
            attrs["reason"]
          )

        :plan ->
          Training.decide_learning_plan(
            a.current_scope.scope,
            a.company.id,
            id,
            attrs["action"],
            attrs["reason"]
          )
      end

    finish(socket, result, "Decision recorded.", %{})
  end

  def handle_event("open_evaluation", %{"id" => id}, socket) do
    selected =
      Enum.find(
        socket.assigns.evaluations,
        &(&1.id == Support.integer(id) and is_nil(&1.answer))
      )

    if selected do
      {:noreply,
       socket
       |> clear_flash()
       |> assign(selected_evaluation: selected, evaluation_form: to_form(%{}, as: :evaluation))}
    else
      {:noreply, put_flash(socket, :error, "That unanswered evaluation is not available to you.")}
    end
  end

  def handle_event("close_evaluation", _, socket),
    do: {:noreply, assign(socket, selected_evaluation: nil)}

  def handle_event("save_evaluation", _, %{assigns: %{selected_evaluation: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "Choose an unanswered evaluation first.")}

  def handle_event("save_evaluation", %{"evaluation" => attrs}, socket) do
    selected = socket.assigns.selected_evaluation

    values =
      Map.new(selected.criteria, fn c ->
        value = get_in(attrs, ["values", c["code"]])
        {c["code"], if(value in [nil, ""], do: nil, else: Support.integer(value) || value)}
      end)

    {:noreply,
     assign(socket,
       pending_evaluation: {selected, values, attrs["reason"]},
       evaluation_form: to_form(attrs, as: :evaluation),
       selected_evaluation: nil
     )}
  end

  def handle_event("cancel_evaluation", _, socket),
    do: {:noreply, assign(socket, pending_evaluation: nil)}

  def handle_event("confirm_evaluation", _, %{assigns: %{pending_evaluation: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_evaluation", _, socket) do
    {selected, values, reason} = socket.assigns.pending_evaluation
    socket = assign(socket, pending_evaluation: nil)

    case Training.answer_evaluation(
           socket.assigns.current_scope.scope,
           socket.assigns.company.id,
           selected.id,
           values,
           reason
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> clear_flash() |> put_flash(:success, "Evaluation recorded.") |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(selected_evaluation: selected)
         |> put_flash(:error, message(reason))
         |> load()}
    end
  end

  def handle_event("save_currencies", %{"currencies" => %{"values" => values}}, socket) do
    values = String.split(values, ~r/[\s,]+/, trim: true)

    finish(
      socket,
      Training.put_learning_currencies(
        socket.assigns.current_scope.scope,
        socket.assigns.company.id,
        values
      ),
      "Currencies saved.",
      %{}
    )
  end

  defp finish(socket, {:ok, _}, message, _),
    do:
      {:noreply,
       socket |> clear_flash() |> assign(modal: false) |> put_flash(:success, message) |> load()}

  defp finish(socket, {:error, reason}, _, attrs),
    do:
      {:noreply,
       socket |> assign(form: to_form(attrs, as: :entry)) |> put_flash(:error, message(reason))}

  defp message(:budget_exceeded),
    do:
      "This approval exceeds the effective budget. Ask the budget operator to review the allocation."

  defp message(:budget_unavailable),
    do:
      "No budget policy covers this request's currency and proposed date. Ask the budget operator to allocate one."

  defp message(:currency_unavailable), do: "This currency is not enabled for the company."

  defp message(:overlapping_policy),
    do: "A budget policy already covers part of that period for this currency."

  defp message(:superseded_budget),
    do: "Another correction has already replaced this budget policy."

  defp message(:budget_below_commitments),
    do:
      "Approved requests in that period already exceed this allocation. Enter an allocation at least equal to the committed amount."

  defp message(:commitments_outside_period),
    do:
      "Requests approved under this policy fall outside the corrected period. Keep their proposed dates within it."

  defp message(:outside_team), do: "This employee is outside your current reporting line."

  defp message(:employee_unavailable),
    do:
      "No current employee is linked to your login. Ask an operator to check your employee link."

  defp message(:self_approval), do: "You cannot review or approve your own learning record."
  defp message(:not_owner), do: "Only the accountable owner can do that."
  defp message(:reason_required), do: "Enter a reason for this decision."
  defp message(:items_required), do: "A plan needs at least one learning item."

  defp message(:invalid_transition),
    do: "That action is unavailable in the record's current state. Refresh and review it again."

  defp message(:superseded_plan), do: "Another amendment has already replaced this plan."
  defp message(:invalid_period), do: "The end date must be on or after the start date."

  defp message(:invalid_currencies),
    do: "Enter currency codes as three uppercase letters, separated by commas."

  defp message(:request_unapproved), do: "A plan can link only an approved team request."

  defp message(%Ecto.Changeset{}),
    do:
      "Check required fields, dates and amounts. Amounts must be nonnegative with up to four decimal places."

  defp message(reason), do: Support.message(reason)

  defp load(socket) do
    a = socket.assigns
    scope = a.current_scope.scope

    can_read_records =
      not (a.audience == :self and a.kind == :request) or
        (a.company != nil and
           Training.allowed?(scope, a.company.id, "people.training.requests.submit"))

    result =
      if a.company do
        case a.kind do
          :request ->
            if(can_read_records,
              do: Training.learning_requests(scope, a.company.id, a.audience),
              else: {:ok, []}
            )

          :plan ->
            Training.learning_plans(scope, a.company.id, a.audience)

          :budget ->
            Training.learning_budgets(scope, a.company.id)
        end
      else
        {:error, :company_unavailable}
      end

    {records, error} =
      case result do
        {:ok, records} -> {records, nil}
        {:error, reason} -> {[], message(reason)}
      end

    can = fn suffix ->
      a.company != nil and error == nil and
        Training.allowed?(scope, a.company.id, "people.training." <> suffix)
    end

    create? =
      case {a.kind, a.audience} do
        {:request, :self} -> can.("requests.submit")
        {:plan, :team} -> can.("plans.submit")
        {:budget, _} -> can.("budgets.manage")
        _ -> false
      end

    flags =
      Map.new(
        ~w(requests.submit requests.recommend requests.review requests.approve plans.submit plans.approve budgets.manage),
        &{&1, can.(&1)}
      )

    record_page = Support.page(records, a.params)

    histories =
      with true <- a.kind != :budget and a.company != nil,
           {:ok, histories} <-
             Training.learning_histories(
               scope,
               a.company.id,
               a.kind,
               Enum.map(record_page.entries, & &1.id),
               a.audience
             ) do
        histories
      else
        _ -> %{}
      end

    currencies =
      if a.kind == :budget and a.company do
        case Training.learning_currencies(scope, a.company.id) do
          {:ok, values} -> values
          _ -> []
        end
      else
        []
      end

    evaluate? =
      a.audience == :self and a.company != nil and
        Enum.all?(
          ~w(requests.submit evaluation.submit),
          &Training.allowed?(scope, a.company.id, "people.training." <> &1)
        )

    {evaluations, evaluation_error} =
      if evaluate? do
        case Training.evaluation_reviews(scope, a.company.id, "evaluation") do
          {:ok, rows} -> {rows, nil}
          {:error, reason} -> {[], message(reason)}
        end
      else
        {[], nil}
      end

    assign(socket,
      can_evaluate?: evaluate?,
      evaluations: evaluations,
      evaluation_error: evaluation_error,
      records: records,
      record_page: record_page,
      histories: histories,
      error: error,
      can_read_records?: can_read_records,
      can_create?: create?,
      can_write?: create? or Enum.any?(records, &(actions(&1, a.kind, a.audience, flags) != [])),
      flags: flags,
      tabs:
        Enum.filter(
          @destinations ++
            [
              {"My passport & evidence", "/people/training/records/my", {:passport, :self}},
              {"Team passports", "/people/training/records/team", {:passport, :team}},
              {"Evaluation policy & effectiveness", "/people/training/effectiveness",
               "people.training.effectiveness.view"}
            ],
          fn
            {_, _, {:passport, audience}} ->
              a.company && Passport.allowed?(scope, a.company.id, audience)

            {_, _, cap} ->
              a.company && Training.allowed?(scope, a.company.id, cap)
          end
        ),
      currencies_form: to_form(%{"values" => Enum.join(currencies, ", ")}, as: :currencies),
      filters:
        to_form(
          %{
            "company_id" => if(a.company, do: to_string(a.company.id), else: ""),
            "perPage" => a.params["perPage"] || "25"
          },
          as: :filters
        )
    )
  end

  defp actions(row, :request, audience, flags) do
    candidates =
      case {row.status, audience} do
        {"draft", :self} ->
          [{"Submit", "submit", "requests.submit"}, {"Cancel", "cancel", "requests.submit"}]

        {state, :self} when state in ~w(pending_hod pending_hr pending_approval) ->
          [{"Cancel", "cancel", "requests.submit"}]

        {"pending_hod", :team} ->
          [
            {"Recommend", "recommend", "requests.recommend"},
            {"Reject", "reject", "requests.recommend"}
          ]

        {"pending_hr", :hr} ->
          [{"Review", "review", "requests.review"}, {"Reject", "reject", "requests.review"}]

        {"pending_approval", :hr} ->
          [{"Approve", "approve", "requests.approve"}, {"Reject", "reject", "requests.approve"}]

        _ ->
          []
      end

    for {label, action, cap} <- candidates, flags[cap], do: {label, action}
  end

  defp actions(row, :plan, audience, flags) do
    cond do
      row.status == "draft" and audience == :team and flags["plans.submit"] ->
        [{"Submit", "submit"}, {"Cancel", "cancel"}]

      row.status == "submitted" and audience == :hr and flags["plans.approve"] ->
        [{"Approve", "approve"}, {"Reject", "reject"}]

      true ->
        []
    end
  end

  defp actions(_, _, _, _), do: []
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page class="space-y-4">
        <.header>{@page_title}<:actions :if={@can_create?}><.button phx-click="open_entry">Add {@kind}</.button></:actions></.header>
        <nav aria-label="Learning tasks" class="flex flex-wrap gap-4 border-b border-line pb-2">
          <.link :for={{label, path, _} <- @tabs} navigate={path <> "?company_id=" <> to_string(@company.id)} aria-current={if path == @path, do: "page"} class="text-link">{label}</.link>
        </nav>
        <.empty_state :if={not @can_read_records?} title="Choose a learning task" reason="Use your authorized passport, evidence or evaluation tasks above. Request submission needs separate access." />
        <.filter_toolbar id="learning-filters" form={@filters} event="select_company">
          <:control type={:select} field={@filters[:company_id]} id="learning-company" label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <p :if={not @can_write? and is_nil(@error)} class="text-sm text-ink-muted">Read-only. Ask an operator to assign access for your learning task.</p>
        <.form :if={@kind == :budget and @flags["budgets.manage"]} for={@currencies_form} id="learning-currencies" phx-submit="save_currencies" class="flex items-end gap-3">
          <.input field={@currencies_form[:values]} label="Company currencies" placeholder="Comma-separated currency codes" />
          <.button type="submit" phx-disable-with="Saving…">Save currencies</.button>
        </.form>
        <.table :if={is_nil(@error) and @can_read_records?} id="learning-records" rows={@record_page.entries} row_id={&"learning-#{&1.id}"}>
          <:col :let={r} label="Record">
            <div :if={@kind == :request}><strong>{r.need}</strong><p>{r.objective}</p><p>{r.expected_result}</p><span>Employee {r.employee_id}</span></div>
            <div :if={@kind == :plan}><strong>{r.objectives}</strong><span> · Version {r.version}</span><p>{r.period_start} – {r.period_end}</p>
              <details><summary>Learning items</summary><dl :for={item <- r.items} class="py-2"><dt>{item.need}</dt><dd>{item.expected_result}</dd><dd>{item.target_cohort} · {item.responsible_owner}</dd><dd>{item.intended_timing} · {item.evaluation_approach}</dd></dl></details>
            </div>
            <div :if={@kind == :budget}><strong>{r.currency}</strong><p>{r.effective_from} – {r.effective_to}</p><p>{r.reason}</p><p :if={r.supersedes_id}>Corrects policy {r.supersedes_id}</p></div>
          </:col>
          <:col :let={r} label="Status / budget">
            <span :if={@kind != :budget}>{r.status}</span>
            <span :if={@kind == :budget and r.superseded_by}>Superseded by policy {r.superseded_by}</span>
            <p :if={@kind == :request}>{r.estimated_cost} {r.currency} · {r.proposed_on}</p>
            <div :if={@kind == :budget}><p>Allocation {r.amount}</p><p>Committed {r.committed}</p><p>Remaining {r.remaining}</p></div>
          </:col>
          <:col :let={r} label="Decisions">
            <details :if={@kind != :budget}><summary>History</summary><p :for={d <- Map.get(@histories, r.id, [])}>{d.action} · User {d.actor_user_id}<span :if={d.impersonator_id}> · Impersonator {d.impersonator_id}</span> · {d.reason} · <.datetime id={"learning-decision-#{@kind}-#{d.id}"} value={d.inserted_at} /></p></details>
            <.form :if={actions(r, @kind, @audience, @flags) != []} for={@decision_form} id={"decision-#{r.id}"} phx-submit="decide" class="space-y-2">
              <input type="hidden" name="decision[id]" value={r.id} />
              <.input field={@decision_form[:action]} type="select" label="Action" options={actions(r, @kind, @audience, @flags)} />
              <.input field={@decision_form[:reason]} label="Reason" required maxlength="4000" />
              <.button type="submit" phx-disable-with="Recording…">Record decision</.button>
            </.form>
            <.button :if={@kind == :plan and r.status == "approved" and @can_create?} phx-click="open_entry" phx-value-prior_id={r.id}>Amend</.button>
            <.button :if={@kind == :budget and is_nil(r.superseded_by) and @can_create?} phx-click="open_entry" phx-value-prior_id={r.id}>Correct</.button>
          </:col>
          <:empty :if={@record_page.entries == []} title="No learning records yet" reason="Choose a company and add a request, plan or budget when you have the required access." />
        </.table>
        <.pagination :if={is_nil(@error) and @can_read_records?} id="learning-pagination" page={@record_page} filters_form={@filters} filters_event="select_company" />
        <section :if={@can_evaluate?} id="my-evaluations" class="space-y-3">
          <.section_heading title="My evaluations"><:description>Evaluate your own learning after a confirmed session. Leave a score blank when the outcome is unknown.</:description></.section_heading>
          <.alert :if={@evaluation_error} kind={:error}>{@evaluation_error}</.alert>
          <.table :if={is_nil(@evaluation_error)} id="my-evaluation-tasks" rows={@evaluations} row_id={&"evaluation-#{&1.id}"}>
            <:col :let={r} label="Session">{r.session_id}</:col>
            <:col :let={r} label="Due">{r.due_on}</:col>
            <:col :let={r} label="Criteria version">{r.policy_version}</:col>
            <:col :let={r} label="Status">{cond do r.answer -> "Answered"; r.reminder -> "Reminder available"; true -> "Awaiting answer" end}</:col>
            <:col :let={r} label="Answer">
              <button :if={is_nil(r.answer)} type="button" phx-click="open_evaluation" phx-value-id={r.id} class="text-link">Answer</button>
              <span :if={r.answer}>{r.answer.reason}</span>
              <p :for={c <- r.criteria} :if={r.answer} class="text-sm">{c["label"]}: {if is_nil(r.answer.values[c["code"]]), do: "Unknown", else: r.answer.values[c["code"]]}</p>
            </:col>
            <:empty :if={@evaluations == []} title="No evaluations yet" reason="An evaluation appears here after an operator prepares reviews for a confirmed session you attended." />
          </.table>
        </section>
        <.modal :if={@selected_evaluation} id="my-evaluation-modal" title="Answer evaluation" flash={@flash} on_cancel={JS.push("close_evaluation")}>
          <.form for={@evaluation_form} id="my-evaluation-form" phx-submit="save_evaluation" class="space-y-3">
            <p>Leave a score blank when the outcome is unknown. Submitted answers are permanent.</p>
            <.input :for={c <- @selected_evaluation.criteria} type="number" name={"evaluation[values][#{c["code"]}]"} value={get_in(@evaluation_form.params, ["values", c["code"]])} label={c["label"]} min={c["minimum"]} max={c["maximum"]} />
            <.input field={@evaluation_form[:reason]} type="textarea" label="Evidence and explanation" required maxlength="4000" />
            <.button type="submit">Review answer</.button>
          </.form>
        </.modal>
        <.confirm_dialog :if={@pending_evaluation} id="my-evaluation-confirm" consequence="This evaluation will be recorded permanently." detail="The criteria version and explanation are preserved. This cannot be undone." confirm="Submit" working="Submitting…" on_confirm={JS.push("confirm_evaluation")} on_cancel={JS.push("cancel_evaluation")} />
        <.confirm_dialog :if={@pending_decision} id="learning-decision-confirm"
          consequence={"Record #{@pending_decision["action"]} for this learning record?"}
          detail="The decision and your reason will remain in history. A terminal request cannot be reopened; an approved plan needs a reasoned amendment."
          confirm="Record decision" working="Recording…" on_confirm={JS.push("confirm_decision")} on_cancel={JS.push("cancel_decision")} />
        <.modal :if={@modal} id="learning-entry" title={cond do
          @prior_id && @kind == :budget -> "Correct budget policy"
          @prior_id -> "Amend plan"
          true -> "Add #{@kind}"
        end} on_cancel={JS.push("close_modal")} flash={@flash}>
          <.form for={@form} id="learning-entry-form" phx-submit="save_entry" class="space-y-3">
            <div :if={@kind == :request} class="space-y-3">
              <.input field={@form[:need]} label="Learning need" required maxlength="4000" />
              <.input field={@form[:objective]} label="Learning objective" type="textarea" required maxlength="4000" />
              <.input field={@form[:expected_result]} label="Expected result" required maxlength="4000" />
              <.input field={@form[:proposed_on]} type="date" label="Proposed date" required />
              <.input field={@form[:estimated_cost]} type="number" label="Estimated cost" min="0" step="0.0001" required />
              <.input field={@form[:currency]} label="Currency" required maxlength="3" />
            </div>
            <div :if={@kind == :budget} class="space-y-3">
              <.input :if={is_nil(@prior_id)} field={@form[:currency]} label="Currency" required maxlength="3" />
              <.input field={@form[:effective_from]} type="date" label="Effective from" required />
              <.input field={@form[:effective_to]} type="date" label="Effective through" required />
              <.input field={@form[:amount]} type="number" label="Allocation" min="0" step="0.0001" required />
              <.input field={@form[:reason]} type="textarea" label={if @prior_id, do: "Correction reason", else: "Allocation reason"} required maxlength="4000" />
            </div>
            <div :if={@kind == :plan} class="space-y-3">
              <.input field={@form[:objectives]} type="textarea" label="Objectives" required maxlength="4000" />
              <.input field={@form[:period_start]} type="date" label="Period start" required />
              <.input field={@form[:period_end]} type="date" label="Period end" required />
              <.input field={@form[:reason]} type="textarea" label="Creation or amendment reason" required maxlength="4000" />
              <fieldset :for={i <- 0..(@item_count - 1)} class="space-y-2 border-t border-line pt-2"><legend>Learning item {i + 1}</legend>
                <.input :for={{field, label} <- [{"need", "Need"}, {"expected_result", "Expected result"}, {"target_cohort", "Target cohort"}, {"responsible_owner", "Responsible owner"}, {"intended_timing", "Intended timing"}, {"evaluation_approach", "Evaluation approach"}]} name={"items[#{i}][#{field}]"} id={"item-#{i}-#{field}"} value="" label={label} required maxlength="4000" />
              </fieldset>
              <.button type="button" phx-click="add_item">Add learning item</.button>
            </div>
            <div class="flex justify-end gap-3"><button type="button" phx-click="close_modal">Cancel</button><.button type="submit" phx-disable-with="Saving…">Save</.button></div>
          </.form>
        </.modal>
      </.page>
    </Layouts.app>
    """
  end
end
