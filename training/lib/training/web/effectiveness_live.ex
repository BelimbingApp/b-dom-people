defmodule Bilimbi.People.Training.Web.EffectivenessLive do
  @moduledoc "HOD effectiveness reviews and the frozen privacy-protected HR summary."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.Web.Support
  @answer_events ~w(open_answer save_answer confirm_answer)
  @policy_events ~w(open_policy add_criterion save_policy confirm_policy)
  @maintenance_events ~w(prepare_reviews run_reminders freeze_summaries)

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       page_title: "Effectiveness",
       modal: nil,
       criterion_counts: %{"criteria" => 1, "effectiveness_criteria" => 1},
       selected_review: nil,
       pending: nil,
       form: to_form(%{}, as: :entry),
       companies:
         Support.companies(socket.assigns.current_scope, "people.training.effectiveness.view")
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply,
     socket
     |> assign(
       company: Support.company(socket.assigns.companies, params),
       params: params,
       modal: nil,
       pending: nil
     )
     |> load()}
  end

  @impl true
  def handle_event(event, _, %{assigns: %{can_answer?: false}} = socket)
      when event in @answer_events,
      do: {:noreply, put_flash(socket, :error, "You cannot answer this company's reviews.")}

  def handle_event(event, _, %{assigns: %{can_policy?: false}} = socket)
      when event in @policy_events,
      do: {:noreply, put_flash(socket, :error, "You cannot publish this company's policy.")}

  def handle_event(event, _, %{assigns: %{can_remind?: false}} = socket)
      when event in @maintenance_events,
      do: {:noreply, put_flash(socket, :error, "You cannot prepare this company's reminders.")}

  def handle_event("select_company", %{"filters" => attrs}, socket),
    do: {:noreply, patch(socket, Map.merge(socket.assigns.params, attrs) |> Map.put("page", "1"))}

  def handle_event("page", %{"page" => page}, socket),
    do: {:noreply, patch(socket, Map.put(socket.assigns.params, "page", page))}

  def handle_event("open_answer", %{"id" => id}, socket) do
    selected =
      Enum.find(socket.assigns.reviews, &(&1.id == Support.integer(id) and is_nil(&1.answer)))

    if selected do
      {:noreply,
       socket
       |> clear_flash()
       |> assign(modal: :answer, selected_review: selected, form: to_form(%{}, as: :entry))}
    else
      {:noreply, put_flash(socket, :error, "That unanswered review is not available to you.")}
    end
  end

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("save_answer", _, %{assigns: %{selected_review: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "Choose an unanswered review first.")}

  def handle_event("save_answer", %{"entry" => attrs}, socket) do
    values =
      Map.new(socket.assigns.selected_review.criteria, fn c ->
        value = get_in(attrs, ["values", c["code"]])
        {c["code"], if(value in [nil, ""], do: nil, else: Support.integer(value) || value)}
      end)

    {:noreply,
     assign(socket,
       pending: {:answer, socket.assigns.selected_review.id, values, attrs["reason"]},
       form: to_form(attrs, as: :entry),
       modal: nil
     )}
  end

  def handle_event(
        "confirm_answer",
        _,
        %{assigns: %{pending: {:answer, id, values, reason}}} = socket
      ) do
    {:noreply,
     finish(
       socket,
       Training.answer_evaluation(
         socket.assigns.current_scope.scope,
         socket.assigns.company.id,
         id,
         values,
         reason
       ),
       "Review answer recorded."
     )}
  end

  def handle_event("open_policy", _, socket),
    do:
      {:noreply,
       socket
       |> clear_flash()
       |> assign(
         modal: :policy,
         criterion_counts: %{"criteria" => 1, "effectiveness_criteria" => 1},
         form: to_form(%{}, as: :entry)
       )}

  def handle_event("add_criterion", %{"kind" => kind}, socket)
      when kind in ["criteria", "effectiveness_criteria"] do
    counts = Map.update!(socket.assigns.criterion_counts, kind, &min(&1 + 1, 50))
    {:noreply, assign(socket, criterion_counts: counts)}
  end

  def handle_event("save_policy", %{"entry" => attrs}, socket) do
    form = to_form(attrs, as: :entry)

    attrs =
      Enum.reduce(["criteria", "effectiveness_criteria"], attrs, fn kind, acc ->
        criteria =
          attrs
          |> Map.get(kind, %{})
          |> Enum.sort_by(fn {key, _} -> Support.integer(key) end)
          |> Enum.map(fn {_, c} ->
            c
            |> Map.update("minimum", nil, &Support.integer/1)
            |> Map.update("maximum", nil, &Support.integer/1)
          end)

        Map.put(acc, kind, criteria)
      end)

    {:noreply, assign(socket, modal: nil, form: form, pending: {:policy, attrs})}
  end

  def handle_event("confirm_policy", _, %{assigns: %{pending: {:policy, attrs}}} = socket) do
    {:noreply,
     finish(
       socket,
       Training.publish_evaluation_policy(
         socket.assigns.current_scope.scope,
         socket.assigns.company.id,
         attrs
       ),
       "Policy version published."
     )}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, pending: nil)}

  def handle_event("prepare_reviews", %{"entry" => attrs}, socket) do
    result =
      Training.prepare_evaluation_reviews(
        socket.assigns.current_scope.scope,
        socket.assigns.company.id,
        Support.integer(attrs["session_id"]),
        DateTime.utc_now()
      )

    message =
      case result do
        {:ok, %{unknown: unknown}} when unknown > 0 ->
          "Session reviews prepared. #{unknown} attendee(s) are no longer current employees and were skipped."

        _ ->
          "Session reviews prepared."
      end

    {:noreply, finish(socket, result, message)}
  end

  def handle_event("freeze_summaries", _, socket) do
    {:noreply,
     finish(
       socket,
       Training.freeze_effectiveness_summaries(
         socket.assigns.current_scope.scope,
         socket.assigns.company.id,
         today(socket)
       ),
       "Closed reporting periods frozen."
     )}
  end

  def handle_event("run_reminders", _, socket) do
    {:noreply,
     finish(
       socket,
       Training.evaluation_reminders(
         socket.assigns.current_scope.scope,
         socket.assigns.company.id,
         today(socket)
       ),
       "Due reminder worklist refreshed."
     )}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp finish(socket, result, message) do
    editor =
      case socket.assigns.pending do
        {:answer, _, _, _} -> :answer
        {:policy, _} -> :policy
        _ -> socket.assigns.modal
      end

    socket = assign(socket, pending: nil)

    case result do
      {:ok, _} ->
        socket |> assign(modal: nil) |> put_flash(:success, message) |> load()

      {:error, reason} ->
        socket |> assign(modal: editor) |> put_flash(:error, Support.message(reason)) |> load()
    end
  end

  defp patch(socket, params),
    do: push_patch(socket, to: "/people/training/effectiveness?" <> URI.encode_query(params))

  defp today(socket) do
    zone =
      Bilimbi.Base.DateTime.company_timezone(
        Bilimbi.Base.Settings.Scope.company(
          socket.assigns.company.id,
          Bilimbi.Base.Tenancy.Scope.tenant_id(socket.assigns.current_scope.scope)
        )
      )

    {:ok, local} =
      DateTime.shift_zone(DateTime.utc_now(), zone, Bilimbi.Base.DateTime.time_zone_database())

    DateTime.to_date(local)
  end

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company = socket.assigns.company

    allowed = fn cap ->
      company != nil and Training.allowed?(scope, company.id, "people.training." <> cap)
    end

    entry? = allowed.("effectiveness.view")
    policy? = entry? and allowed.("evaluation.policy.manage")
    remind? = entry? and allowed.("evaluation.reminders.manage")
    review? = entry? and allowed.("effectiveness.answer")
    summary? = entry? and allowed.("effectiveness.summary.view")

    {reviews, review_error} =
      read_rows(review?, fn -> Training.evaluation_reviews(scope, company.id, "effectiveness") end)

    {policies, policy_error} =
      read_rows(policy?, fn -> Training.evaluation_policies(scope, company.id) end)

    period_start =
      with true <- policy?,
           {:ok, %Date{} = date} <- Training.effectiveness_period_start(scope, company.id) do
        date
      else
        _ -> nil
      end

    {summaries, summary_error} =
      read_rows(summary?, fn -> Training.effectiveness_summary(scope, company.id) end)

    assign(socket,
      can_answer?: review?,
      can_policy?: policy?,
      can_remind?: remind?,
      can_summary?: summary?,
      reviews: reviews,
      review_page: Support.page(reviews, socket.assigns.params),
      policies: policies,
      summaries: summaries,
      period_start: period_start,
      error:
        if(entry?,
          do: review_error || policy_error || summary_error,
          else: "No company is available. Ask an operator to check your company access."
        ),
      filters:
        to_form(
          %{
            "company_id" => if(company, do: to_string(company.id), else: ""),
            "perPage" => socket.assigns.params["perPage"] || "25"
          },
          as: :filters
        ),
      maintenance_form: to_form(%{}, as: :entry)
    )
  end

  defp read_rows(false, _), do: {[], nil}

  defp read_rows(true, fun) do
    case fun.() do
      {:ok, rows} -> {rows, nil}
      {:error, reason} -> {[], Support.message(reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people.development.effectiveness">
      <.page class="space-y-4">
        <.header>Effectiveness
          <:actions :if={@can_policy?}><.button phx-click="open_policy">Publish criteria</.button></:actions>
        </.header>
        <.filter_toolbar id="effectiveness-filters" form={@filters} event="select_company">
          <:control type={:select} field={@filters[:company_id]} id="effectiveness-company" label="Company" options={Enum.map(@companies, &{&1.name, &1.id})} />
        </.filter_toolbar>
        <.alert :if={@error} kind={:error}>{@error}</.alert>
        <.empty_state :if={not @can_answer? and not @can_summary? and not @can_policy? and not @can_remind? and is_nil(@error)} id="effectiveness-forbidden" title="No review tasks available" reason="Ask an operator to grant HOD review or HR summary access. Employees answer their own evaluations under My learning." />
        <.section_heading :if={@can_answer?} title="Review"><:description>Heads of department answer effectiveness reviews for their current direct reports.</:description></.section_heading>
        <.table :if={@can_answer? and is_nil(@error)} id="effectiveness-reviews" rows={@review_page.entries} row_id={&"review-#{&1.id}"}>
          <:col :let={r} label="Employee">{r.employee_id}</:col>
          <:col :let={r} label="Session">{r.session_id}</:col>
          <:col :let={r} label="Due">{r.due_on}</:col>
          <:col :let={r} label="Criteria version">{r.policy_version}</:col>
          <:col :let={r} label="Status">{cond do r.answer -> "Answered"; r.reminder -> "Reminder available"; true -> "Awaiting answer" end}</:col>
          <:col :let={r} label="Answer">
            <button :if={is_nil(r.answer)} type="button" phx-click="open_answer" phx-value-id={r.id} class="text-link">Answer</button>
            <span :if={r.answer}>{r.answer.reason}</span>
            <p :for={c <- r.criteria} :if={r.answer} class="text-sm">{c["label"]}: {if is_nil(r.answer.values[c["code"]]), do: "Unknown", else: r.answer.values[c["code"]]}</p>
          </:col>
          <:empty title="No reviews yet" reason="An operator prepares reviews after a confirmed session ends." />
        </.table>
        <.pagination :if={@can_answer? and is_nil(@error)} id="effectiveness-pagination" page={@review_page} filters_form={@filters} filters_event="select_company" />
        <.section_heading :if={@can_summary?} title="Summary"><:description>Fixed company reporting periods, frozen after the answer grace window; small cohorts and insufficient known answers are suppressed.</:description></.section_heading>
        <div :if={@can_summary? and is_nil(@error)} id="effectiveness-summary" class="space-y-4">
          <.empty_state :if={@summaries == []} id="summary-empty" title="No frozen reporting period" reason="A period's summary appears once it ends, its answer grace window passes and an operator freezes it." />
          <div :for={period <- @summaries} id={"summary-#{period.period_start}"} class="space-y-2">
            <.section_heading title={"#{period.period_start} – #{period.period_end}"} />
            <p :if={period.status == "suppressed"} id={"summary-suppressed-#{period.period_start}"}>Summary suppressed: the cohort is below this company's disclosure minimum.</p>
            <div :for={group <- period.groups["items"]} :if={period.status == "current"} class="space-y-2">
              <.section_heading title={"#{group["checkpoint_days"]}-day review · criteria version #{group["policy_version"]}"} />
              <p :if={group["status"] == "suppressed"}>Summary suppressed for this cohort.</p>
              <.table :if={group["status"] == "current"} id={"summary-criteria-#{period.period_start}-#{group["policy_version"]}-#{group["checkpoint_days"]}"} rows={group["criteria"]}>
                <:col :let={c} label="Criterion">{c["label"]}</:col>
                <:col :let={c} label="Known answers">{c["answered"] || "Suppressed"}</:col>
                <:col :let={c} label="Mean">{c["mean"] || "Suppressed — insufficient known data"}</:col>
              </.table>
            </div>
          </div>
        </div>
        <.section_heading :if={@can_policy?} title="Published criteria"><:description>Versions and answers are permanent. Publish another effective period to change criteria.</:description></.section_heading>
        <p :if={@can_policy?} class="text-sm">Set due days, checkpoints, reminder lead, reporting period, answer grace and disclosure minimum in <.link navigate="/system/settings" class="text-link">Operator Settings</.link> before publication.</p>
        <p :if={@can_policy? and @period_start} id="report-period-start" class="text-sm">The configured reporting period length takes effect from {@period_start}; a changed length starts the day after the last frozen period.</p>
        <.table :if={@can_policy?} id="evaluation-policies" rows={@policies}>
          <:col :let={p} label="Version">{p.version}</:col>
          <:col :let={p} label="Effective period">{p.effective_from} – {p.effective_to}</:col>
          <:col :let={p} label="Criteria"><p :for={c <- p.criteria["items"]}>{c["label"]}</p><p :for={c <- p.effectiveness_criteria["items"]}>{c["label"]}</p></:col>
          <:col :let={p} label="Reason">{p.reason}</:col>
          <:empty title="No evaluation policy" reason="Configure company settings, then publish effective-dated criteria." />
        </.table>
        <.section_heading :if={@can_remind?} title="Due reminders"><:description>Prepare session reviews, refresh the durable worklist and freeze closed reporting periods. This does not send email.</:description></.section_heading>
        <.form :if={@can_remind?} for={@maintenance_form} id="prepare-review-form" phx-submit="prepare_reviews">
          <.input field={@maintenance_form[:session_id]} type="number" label="Completed session" min="1" required />
          <.button type="submit" phx-disable-with="Preparing…">Prepare reviews</.button>
        </.form>
        <.button :if={@can_remind?} phx-click="run_reminders" phx-disable-with="Refreshing…">Refresh reminders</.button>
        <.button :if={@can_remind?} phx-click="freeze_summaries" phx-disable-with="Freezing…">Freeze closed periods</.button>
        <.modal :if={@modal == :answer} id="evaluation-answer-modal" title="Answer review" flash={@flash} on_cancel={JS.push("close_modal")}>
          <.form for={@form} id="evaluation-answer-form" phx-submit="save_answer" class="space-y-3">
            <p>Leave a score blank when the outcome is unknown. Submitted answers are permanent.</p>
            <.input :for={c <- @selected_review.criteria} type="number" name={"entry[values][#{c["code"]}]"} value={get_in(@form.params, ["values", c["code"]])} label={c["label"]} min={c["minimum"]} max={c["maximum"]} />
            <.input field={@form[:reason]} type="textarea" label="Evidence and explanation" required maxlength="4000" />
            <.button type="submit">Review answer</.button>
          </.form>
        </.modal>
        <.modal :if={@modal == :policy} id="evaluation-policy-modal" title="Publish criteria" flash={@flash} on_cancel={JS.push("close_modal")}>
          <.form for={@form} id="evaluation-policy-form" phx-submit="save_policy" class="space-y-3">
            <.input field={@form[:effective_from]} type="date" label="Effective from" required />
            <.input field={@form[:effective_to]} type="date" label="Effective to" required />
            <div :for={{kind, label} <- [{"criteria", "Employee evaluation"}, {"effectiveness_criteria", "HOD effectiveness"}]} class="space-y-3">
              <.section_heading title={label} />
              <div :for={index <- 1..@criterion_counts[kind]} id={"#{kind}-#{index}"} class="space-y-2">
                <.input name={"entry[#{kind}][#{index}][code]"} value={get_in(@form.params, [kind, to_string(index), "code"]) } label="Criterion code" required maxlength="80" />
                <.input name={"entry[#{kind}][#{index}][label]"} value={get_in(@form.params, [kind, to_string(index), "label"]) } label="Criterion label" required maxlength="160" />
                <.input name={"entry[#{kind}][#{index}][minimum]"} value={get_in(@form.params, [kind, to_string(index), "minimum"]) } type="number" label="Minimum score" required min="-10000" max="10000" />
                <.input name={"entry[#{kind}][#{index}][maximum]"} value={get_in(@form.params, [kind, to_string(index), "maximum"]) } type="number" label="Maximum score" required min="-10000" max="10000" />
              </div>
              <button type="button" phx-click="add_criterion" phx-value-kind={kind} class="text-link">Add criterion</button>
            </div>
            <.input field={@form[:reason]} type="textarea" label="Publication reason" required maxlength="4000" />
            <.button type="submit">Review publication</.button>
          </.form>
        </.modal>
        <.confirm_dialog :if={match?({:answer, _, _, _}, @pending)} id="evaluation-answer-confirm" consequence="This review answer will be recorded permanently." detail="The criteria version and explanation are preserved. This cannot be undone." confirm="Submit" working="Submitting…" on_confirm={JS.push("confirm_answer")} on_cancel={JS.push("cancel_confirm")} />
        <.confirm_dialog :if={match?({:policy, _}, @pending)} id="evaluation-policy-confirm" consequence="This criteria version will be published permanently." detail="It applies to sessions ending in its effective period. Settings are captured at publication." confirm="Publish" working="Publishing…" on_confirm={JS.push("confirm_policy")} on_cancel={JS.push("cancel_confirm")} />
      </.page>
    </Layouts.app>
    """
  end
end
