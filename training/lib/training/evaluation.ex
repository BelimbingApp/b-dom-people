defmodule Bilimbi.People.Training.Evaluation do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy, Settings}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.Settings.Scope, as: SettingScope
  alias Bilimbi.Core.User
  alias Bilimbi.People.{Training, Workforce}
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Training.{
    EffectivenessSummary,
    EvaluationPolicy,
    EvaluationReview,
    EvaluationAnswer,
    EvaluationReminder,
    ParticipationFact,
    Session
  }

  # Employees evaluate under My learning; HODs answer under Effectiveness.
  @task_access %{
    "evaluation" => ~w(requests.submit evaluation.submit),
    "effectiveness" => ~w(effectiveness.view effectiveness.answer)
  }

  def policies(%Scope{} = scope, company) do
    with :ok <- auth(scope, company, "evaluation.policy.manage") do
      {:ok,
       Repo.all(from(p in scoped(EvaluationPolicy, scope, company), order_by: [desc: p.version]))
       |> Enum.map(&view/1)}
    end
  end

  def publish(%Scope{} = scope, company, attrs) do
    with :ok <- auth(scope, company, "evaluation.policy.manage") do
      tx(scope, company, fn ->
        attrs =
          stringify(attrs)
          |> Map.take(~w(effective_from effective_to criteria effectiveness_criteria reason))

        version =
          (Repo.one(from(p in scoped(EvaluationPolicy, scope, company), select: max(p.version))) ||
             0) + 1

        attrs =
          Map.merge(attrs, %{
            "version" => version,
            "evaluation_days" => setting(scope, company, "evaluation_days"),
            "checkpoints" => setting(scope, company, "checkpoints"),
            "reminder_days" => setting(scope, company, "reminder_days")
          })

        require!(
          is_integer(attrs["evaluation_days"]) and is_integer(attrs["reminder_days"]),
          :policy_not_configured
        )

        require!(
          is_list(attrs["checkpoints"]) and length(attrs["checkpoints"]) in 1..24 and
            Enum.all?(attrs["checkpoints"], &(is_integer(&1) and &1 in 1..3650)) and
            Enum.uniq(attrs["checkpoints"]) == attrs["checkpoints"],
          :invalid_checkpoints
        )

        require!(
          criteria_valid?(attrs["criteria"]) and criteria_valid?(attrs["effectiveness_criteria"]),
          :invalid_criteria
        )

        attrs =
          attrs
          |> Map.update!("criteria", &%{"items" => &1})
          |> Map.update!("effectiveness_criteria", &%{"items" => &1})
          |> Map.update!("checkpoints", &%{"days" => &1})

        policy = prepare!(EvaluationPolicy, scope, company, attrs)
        require!(Date.compare(policy.effective_to, policy.effective_from) != :lt, :invalid_period)
        require!(valid_reason?(policy.reason), :reason_required)

        require!(
          not Repo.exists?(
            from(p in scoped(EvaluationPolicy, scope, company),
              where:
                p.effective_from <= ^policy.effective_to and
                  p.effective_to >= ^policy.effective_from
            )
          ),
          :overlapping_policy
        )

        insert!(EvaluationPolicy, scope, company, attrs) |> view()
      end)
    end
  end

  # Explicit maintenance run; no unattended schedule or mail-delivery claim.
  def prepare_reviews(%Scope{} = scope, company, session_id, %DateTime{} = now) do
    with :ok <- auth(scope, company, "evaluation.reminders.manage") do
      tx(scope, company, fn ->
        session = fetch!(Session, scope, company, session_id)
        require!(DateTime.compare(now, session.ends_at) != :lt, :session_not_finished)

        {:ok, local} =
          DateTime.shift_zone(
            session.ends_at,
            session.time_zone,
            Bilimbi.Base.DateTime.time_zone_database()
          )

        finished = DateTime.to_date(local)

        policy =
          Repo.one(
            from(p in scoped(EvaluationPolicy, scope, company),
              where: p.effective_from <= ^finished and p.effective_to >= ^finished
            )
          )

        require!(policy != nil, :policy_unavailable)
        employees = current_employees!(scope, company)

        {facts, unavailable} =
          latest_facts(scope, company, session.id)
          |> Repo.all()
          |> Enum.filter(&(&1.status == "confirmed"))
          |> Enum.split_with(&Map.has_key?(employees, &1.employee_id))

        reviews =
          for fact <- facts,
              {kind, days, offset} <- [
                {"evaluation", 0, policy.evaluation_days}
                | Enum.map(policy.checkpoints["days"], &{"effectiveness", &1, &1})
              ] do
            existing =
              Repo.one(
                from(r in scoped(EvaluationReview, scope, company),
                  join: f in ParticipationFact,
                  on: f.id == r.fact_id,
                  where:
                    f.session_id == ^session.id and f.employee_id == ^fact.employee_id and
                      r.kind == ^kind and r.checkpoint_days == ^days
                )
              )

            # A confirmed correction must not create duplicate review obligations.
            if existing,
              do: view(existing),
              else:
                insert!(EvaluationReview, scope, company, %{
                  policy_id: policy.id,
                  fact_id: fact.id,
                  kind: kind,
                  checkpoint_days: days,
                  due_on: Date.add(finished, offset)
                })
                |> view()
          end

        %{reviews: reviews, unknown: length(unavailable)}
      end)
    end
  end

  def reviews(%Scope{} = scope, company, kind) when kind in ["evaluation", "effectiveness"] do
    with :ok <- task_auth(scope, company, kind),
         {:ok, self} <- self_employee(scope, company),
         {:ok, read} <- Workforce.employees(scope, company),
         {:ok, employees} <- ReadResult.require_current(read) do
      ids =
        if kind == "evaluation",
          do: [self],
          else:
            for(
              e <- employees,
              e.supervisor_reference && e.supervisor_reference.stable_id == to_string(self),
              do: integer(e.reference.stable_id)
            )

      {:ok, visible_reviews(scope, company, kind, ids)}
    end
  end

  def answer(%Scope{} = scope, company, id, values, reason) do
    with true <-
           Enum.any?(Map.keys(@task_access), &(task_auth(scope, company, &1) == :ok)) ||
             {:error, :unauthorized} do
      tx(scope, company, fn ->
        review = fetch!(EvaluationReview, scope, company, id)
        require!(task_auth(scope, company, review.kind) == :ok, :unauthorized)
        fact = fetch!(ParticipationFact, scope, company, review.fact_id)
        fetch!(Session, scope, company, fact.session_id)
        current_fact!(scope, company, fact)
        employees = current_employees!(scope, company)
        subject = employees[fact.employee_id]
        require!(subject != nil, :employee_unavailable)
        {:ok, self} = self_employee_or_rollback(scope, company)

        permitted =
          if review.kind == "evaluation",
            do: self == fact.employee_id,
            else:
              subject.supervisor_reference != nil and
                subject.supervisor_reference.stable_id == to_string(self) and
                self != fact.employee_id

        require!(permitted, :outside_team)

        require!(
          not Repo.exists?(
            from(a in scoped(EvaluationAnswer, scope, company), where: a.review_id == ^review.id)
          ),
          :already_answered
        )

        policy = fetch!(EvaluationPolicy, scope, company, review.policy_id)

        criteria =
          if review.kind == "evaluation",
            do: policy.criteria["items"],
            else: policy.effectiveness_criteria["items"]

        require!(answers_valid?(criteria, values), :invalid_answers)
        require!(valid_reason?(reason), :reason_required)

        insert!(EvaluationAnswer, scope, company, %{
          review_id: review.id,
          values: values,
          reason: String.trim(reason)
        })
        |> view()
      end)
    end
  end

  def remind(%Scope{} = scope, company, %Date{} = today) do
    with :ok <- auth(scope, company, "evaluation.reminders.manage") do
      tx(scope, company, fn ->
        employees = current_employees!(scope, company)

        reviews =
          Repo.all(
            from(r in scoped(EvaluationReview, scope, company),
              join: p in EvaluationPolicy,
              on: p.id == r.policy_id,
              left_join: a in EvaluationAnswer,
              on: a.review_id == r.id,
              left_join: m in EvaluationReminder,
              on: m.review_id == r.id,
              where: is_nil(a.id) and is_nil(m.id),
              select: {r, p.reminder_days}
            )
          )

        Enum.reduce(reviews, %{created: 0, unknown: 0}, fn {review, lead}, result ->
          fact = fetch!(ParticipationFact, scope, company, review.fact_id)

          if current_confirmed?(scope, company, fact) and
               Date.compare(today, Date.add(review.due_on, -lead)) != :lt do
            subject = employees[fact.employee_id]

            recipient =
              cond do
                subject == nil -> nil
                review.kind == "evaluation" -> fact.employee_id
                subject.supervisor_reference -> integer(subject.supervisor_reference.stable_id)
                true -> nil
              end

            if recipient && Map.has_key?(employees, recipient) do
              insert!(EvaluationReminder, scope, company, %{
                review_id: review.id,
                recipient_employee_id: recipient,
                available_on: today
              })

              %{result | created: result.created + 1}
            else
              %{result | unknown: result.unknown + 1}
            end
          else
            result
          end
        end)
      end)
    end
  end

  # Frozen snapshots only; reads never recompute, so readings cannot be differenced.
  def summary(%Scope{} = scope, company) do
    with :ok <- auth(scope, company, "effectiveness.summary.view") do
      {:ok,
       Repo.all(
         from(s in scoped(EffectivenessSummary, scope, company), order_by: [desc: s.period_start])
       )
       |> Enum.map(&view/1)}
    end
  end

  # Explicit maintenance run. A fixed calendar period freezes once, after its
  # answer grace window; no arbitrary cohort drill or complement totals exist.
  # Both population and non-null answers must meet the operator threshold.
  def freeze_summaries(%Scope{} = scope, company, %Date{} = today) do
    with :ok <- auth(scope, company, "evaluation.reminders.manage") do
      minimum = setting(scope, company, "minimum_cohort")
      months = setting(scope, company, "report_months")
      grace = setting(scope, company, "report_grace_days")

      if is_integer(minimum) and minimum in 2..1000 and is_integer(months) and
           months in 1..12 and rem(12, months) == 0 and is_integer(grace) and grace in 0..3650 do
        tx(scope, company, fn ->
          employees = current_employees!(scope, company)

          periods =
            scope
            |> next_period_start(company, months)
            |> closed_periods(months, today, grace)

          for {first, last} <- periods do
            insert!(
              EffectivenessSummary,
              scope,
              company,
              snapshot(scope, company, employees, first, last, minimum)
            )
          end

          %{frozen: length(periods)}
        end)
      else
        {:error, :report_not_configured}
      end
    end
  end

  def period_start(%Scope{} = scope, company) do
    with :ok <- auth(scope, company, "evaluation.policy.manage") do
      months = setting(scope, company, "report_months")

      if is_integer(months) and months in 1..12 and rem(12, months) == 0,
        do: {:ok, next_period_start(scope, company, months)},
        else: {:error, :report_not_configured}
    end
  end

  # Periods form one contiguous chain: a changed length applies from the day
  # after the last frozen period, so snapshots never overlap or leave a gap.
  defp next_period_start(scope, company, months) do
    last =
      Repo.one(from(s in scoped(EffectivenessSummary, scope, company), select: max(s.period_end)))

    first_due =
      Repo.one(
        from(r in scoped(EvaluationReview, scope, company),
          where: r.kind == "effectiveness",
          select: min(r.due_on)
        )
      )

    cond do
      last -> Date.add(last, 1)
      first_due -> Date.new!(first_due.year, div(first_due.month - 1, months) * months + 1, 1)
      true -> nil
    end
  end

  defp closed_periods(nil, _, _, _), do: []

  defp closed_periods(first, months, today, grace) do
    last = first |> Date.shift(month: months) |> Date.add(-1)

    if Date.compare(today, Date.add(last, grace)) == :gt,
      do: [{first, last} | closed_periods(Date.add(last, 1), months, today, grace)],
      else: []
  end

  defp snapshot(scope, company, employees, first, last, minimum) do
    ids = Map.keys(employees)

    rows =
      Repo.all(
        from(r in scoped(EvaluationReview, scope, company),
          join: f in ParticipationFact,
          on: f.id == r.fact_id,
          join: p in EvaluationPolicy,
          on: p.id == r.policy_id,
          left_join: a in EvaluationAnswer,
          on: a.review_id == r.id,
          where:
            r.kind == "effectiveness" and r.due_on >= ^first and r.due_on <= ^last and
              f.employee_id in ^ids,
          select: {r, f, p, a}
        )
      )
      |> Enum.filter(fn {_, f, _, _} -> current_confirmed?(scope, company, f) end)

    base = %{period_start: first, period_end: last, minimum_cohort: minimum}

    if distinct_subjects(rows) < minimum do
      Map.merge(base, %{status: "suppressed", groups: %{"items" => []}})
    else
      groups =
        rows
        |> Enum.group_by(fn {r, _, p, _} -> {p.id, r.checkpoint_days} end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {{_, days}, cohort} -> aggregate(days, cohort, minimum) end)

      Map.merge(base, %{status: "current", groups: %{"items" => groups}})
    end
  end

  defp aggregate(days, cohort, minimum) do
    {_, _, policy, _} = hd(cohort)
    group = %{"policy_version" => policy.version, "checkpoint_days" => days}

    if distinct_subjects(cohort) < minimum do
      Map.merge(group, %{"status" => "suppressed", "criteria" => []})
    else
      criteria =
        Enum.map(policy.effectiveness_criteria["items"], fn c ->
          known =
            for {_, f, _, a} <- cohort,
                a != nil,
                is_integer(a.values[c["code"]]),
                do: {f.employee_id, a.values[c["code"]]}

          if known |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() >= minimum do
            scores = Enum.map(known, &elem(&1, 1))

            mean =
              Decimal.div(Decimal.new(Enum.sum(scores)), Decimal.new(length(scores)))
              |> Decimal.round(2)
              |> Decimal.to_string()

            %{
              "label" => c["label"],
              "status" => "current",
              "answered" => length(scores),
              "mean" => mean
            }
          else
            %{"label" => c["label"], "status" => "suppressed", "answered" => nil, "mean" => nil}
          end
        end)

      Map.merge(group, %{"status" => "current", "criteria" => criteria})
    end
  end

  defp distinct_subjects(rows),
    do: rows |> Enum.map(fn {_, f, _, _} -> f.employee_id end) |> Enum.uniq() |> length()

  defp visible_reviews(scope, company, kind, ids) do
    rows =
      Repo.all(
        from(r in scoped(EvaluationReview, scope, company),
          join: f in ParticipationFact,
          on: f.id == r.fact_id,
          join: p in EvaluationPolicy,
          on: p.id == r.policy_id,
          left_join: a in EvaluationAnswer,
          on: a.review_id == r.id,
          left_join: m in EvaluationReminder,
          on: m.review_id == r.id,
          where: r.kind == ^kind and f.employee_id in ^ids,
          order_by: [asc: r.due_on, asc: r.id],
          select: {r, f, p, a, m}
        )
      )

    for {r, f, p, a, m} <- rows, current_confirmed?(scope, company, f) do
      view(r)
      |> Map.merge(%{
        employee_id: f.employee_id,
        session_id: f.session_id,
        criteria:
          if(kind == "evaluation",
            do: p.criteria["items"],
            else: p.effectiveness_criteria["items"]
          ),
        policy_version: p.version,
        answer: a && view(a),
        reminder: m && %{available_on: m.available_on}
      })
    end
  end

  defp current_fact!(scope, company, fact),
    do: require!(current_confirmed?(scope, company, fact), :attendance_unavailable)

  defp current_confirmed?(scope, company, fact) do
    latest =
      Repo.one(
        from(f in scoped(ParticipationFact, scope, company),
          where: f.session_id == ^fact.session_id and f.employee_id == ^fact.employee_id,
          order_by: [desc: f.revision],
          limit: 1
        )
      )

    latest != nil and latest.status == "confirmed"
  end

  defp latest_facts(scope, company, session),
    do:
      from(f in scoped(ParticipationFact, scope, company),
        where: f.session_id == ^session,
        distinct: f.employee_id,
        order_by: [asc: f.employee_id, desc: f.revision]
      )

  defp current_employees!(scope, company) do
    with {:ok, read} <- Workforce.employees(scope, company),
         {:ok, employees} <- ReadResult.require_current(read),
         do: Map.new(employees, &{integer(&1.reference.stable_id), &1}),
         else: (_ -> Repo.rollback(:employee_unavailable))
  end

  defp self_employee(scope, company) do
    with {:ok, user} <- User.get_user(scope, company, Scope.actor(scope).user_id),
         id when is_integer(id) <- user.employee_id,
         {:ok, read} <- Workforce.employee(scope, company, id),
         {:ok, _} <- ReadResult.require_current(read),
         do: {:ok, id},
         else: (_ -> {:error, :employee_unavailable})
  end

  defp self_employee_or_rollback(scope, company) do
    case self_employee(scope, company) do
      {:ok, _} = ok -> ok
      _ -> Repo.rollback(:employee_unavailable)
    end
  end

  defp criteria_valid?(list) when is_list(list) and length(list) in 1..50 do
    Enum.all?(list, fn c ->
      is_map(c) and Enum.sort(Map.keys(c)) == ~w(code label maximum minimum) and
        is_binary(c["code"]) and Regex.match?(~r/^[a-z][a-z0-9_]{0,79}$/, c["code"]) and
        valid_reason?(c["label"]) and is_integer(c["minimum"]) and is_integer(c["maximum"]) and
        c["minimum"] <= c["maximum"] and c["minimum"] >= -10000 and c["maximum"] <= 10000
    end) and length(Enum.uniq_by(list, & &1["code"])) == length(list)
  end

  defp criteria_valid?(_), do: false

  defp answers_valid?(criteria, values) when is_map(values) do
    Enum.sort(Map.keys(values)) == Enum.sort(Enum.map(criteria, & &1["code"])) and
      Enum.all?(criteria, fn c ->
        value = values[c["code"]]
        is_nil(value) or (is_integer(value) and value >= c["minimum"] and value <= c["maximum"])
      end)
  end

  defp answers_valid?(_, _), do: false
  defp valid_reason?(v), do: is_binary(v) and String.trim(v) != "" and byte_size(v) <= 4000

  defp setting(scope, company, suffix),
    do:
      Settings.get(
        "people.training.evaluation." <> suffix,
        SettingScope.company(company, Scope.tenant_id(scope))
      )

  defp auth(scope, company, suffix),
    do:
      if(Training.allowed?(scope, company, "people.training." <> suffix),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp task_auth(scope, company, kind),
    do:
      if(Enum.all?(@task_access[kind], &(auth(scope, company, &1) == :ok)),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp scoped(schema, scope, company),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company)

  defp fetch!(schema, scope, company, id) do
    require!(is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807, :not_found)

    Repo.one(from(r in scoped(schema, scope, company), where: r.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp prepare!(schema, scope, company, attrs) do
    changeset =
      schema.changeset(
        struct(schema,
          tenant_id: Scope.tenant_id(scope),
          company_id: company,
          actor_user_id: Scope.actor(scope).user_id,
          impersonator_id: Scope.actor(scope).impersonator_id
        ),
        attrs
      )

    require!(changeset.valid?, changeset)
    Ecto.Changeset.apply_changes(changeset)
  end

  defp insert!(schema, scope, company, attrs),
    do: Repo.insert!(prepare!(schema, scope, company, attrs))

  defp tx(scope, company, fun) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "people.training.evaluation:#{Scope.tenant_id(scope)}:#{company}"
      ])

      fun.()
    end)
  end

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)
  defp integer(v), do: String.to_integer(v)
  defp view(row), do: row |> Map.from_struct() |> Map.drop([:__meta__])
  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
