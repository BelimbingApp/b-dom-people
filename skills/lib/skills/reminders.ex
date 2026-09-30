defmodule Bilimbi.People.Skills.Reminders do
  @moduledoc false
  # What is due for one company, and who is told, once per period.
  #
  # A ledger row is written before the notification is sent. Its unique key
  # (rule, employee, skill, action, period, recipient) makes a second run in
  # the same period lose the insert instead of notifying twice. A failed send
  # leaves a visible failed row, and a crash between the insert and the send
  # leaves a pending row; a retry picks up both once the pending row is older
  # than a short grace period. A due item nobody can be found for writes
  # nothing and is counted.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.User
  alias Bilimbi.People.Skills.{Access, Action, Assessments, Policy, Reminder, Score, Standing}

  @send "people.skills.reminders.send"
  @wide "people.skills.assessments.manage"
  @pursued ~w(not_started scheduled in_progress pending_reassessment)
  @stalled_after_seconds 15 * 60

  @titles %{
    "overdue_reassessment" => "Skill reassessment overdue",
    "expiring_certificate" => "Skill validity ending",
    "overdue_action" => "Development action overdue",
    "coverage_gap" => "Critical skill under-covered"
  }

  @doc "Records and sends this period's reminders that were not sent before."
  def issue(actor, company_id, as_of \\ nil) do
    scope = actor.scope
    as_of = as_of || Date.utc_today()

    with {:ok, _company} <- Access.authorize(actor, company_id, @send),
         {:ok, due} <- compute(actor, company_id, as_of) do
      counts =
        Enum.reduce(due, %{sent: 0, failed: 0, skipped: 0, unaddressed: 0}, fn item, counts ->
          case item.recipients do
            [] ->
              Map.update!(counts, :unaddressed, &(&1 + 1))

            recipients ->
              Enum.reduce(recipients, counts, fn recipient, counts ->
                deliver(scope, company_id, item, recipient, as_of, counts)
              end)
          end
        end)

      {:ok, counts}
    end
  end

  @doc "Retries this period's failed and stalled reminders; sent ones are never touched."
  def retry(actor, company_id, as_of \\ nil) do
    scope = actor.scope
    as_of = as_of || Date.utc_today()
    keys = Enum.uniq([week_key(as_of), month_key(as_of)])
    stalled = NaiveDateTime.add(Assessments.now(), -@stalled_after_seconds)

    with {:ok, _company} <- Access.authorize(actor, company_id, @send) do
      rows =
        Repo.all(
          from(r in Tenancy.scope_query(Reminder, scope),
            where: r.company_id == ^company_id and r.period_key in ^keys,
            where: r.state == "failed" or (r.state == "pending" and r.inserted_at < ^stalled),
            order_by: [asc: r.id]
          )
        )

      counts =
        Enum.reduce(rows, %{sent: 0, failed: 0}, fn row, counts ->
          case send_row(scope, row) do
            :sent -> Map.update!(counts, :sent, &(&1 + 1))
            :failed -> Map.update!(counts, :failed, &(&1 + 1))
          end
        end)

      {:ok, counts}
    end
  end

  @doc "The ledger rows addressed to the signed-in user, newest first."
  def inbox(actor, company_id, limit \\ 50) do
    scope = actor.scope

    with {:ok, _company} <- Access.current_company(scope, company_id),
         true <- match?(%{type: :user, company_id: ^company_id}, actor) do
      rows =
        Repo.all(
          from(r in Tenancy.scope_query(Reminder, scope),
            where:
              r.company_id == ^company_id and r.recipient_user_id == ^actor.id and
                r.state == "sent",
            order_by: [desc: r.id],
            limit: ^limit
          )
        )

      {:ok, Enum.map(rows, &view/1)}
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc "What is due as of a day and who would be told, writing nothing."
  def due(actor, company_id, as_of) do
    with {:ok, _company} <- Access.authorize(actor, company_id, @send),
         do: compute(actor, company_id, as_of)
  end

  defp compute(actor, company_id, as_of) do
    scope = actor.scope

    with {:ok, policy} <- Policy.get(scope, company_id),
         {:ok, employees} <- Access.current_employees(scope, company_id),
         {:ok, coverage} <- Standing.critical_coverage(scope, company_id, as_of) do
      supervisors = Map.new(employees, &{Access.employee_id(&1), Access.supervisor_id(&1)})
      users = Access.users_by_employee(scope, company_id)
      horizon = Date.add(as_of, policy.reminder_window_days)

      scores =
        Repo.all(
          from(s in Tenancy.scope_query(Score, scope),
            where: s.company_id == ^company_id and s.employee_id in ^Map.keys(supervisors),
            where:
              s.next_due_on <= ^as_of or (not is_nil(s.valid_until) and s.valid_until <= ^horizon),
            order_by: [asc: s.id]
          )
        )

      overdue =
        for score <- scores, Date.compare(score.next_due_on, as_of) != :gt do
          item(
            "overdue_reassessment",
            score.employee_id,
            score.skill_id,
            nil,
            score.next_due_on,
            supervisor_users(supervisors, users, score.employee_id)
          )
        end

      expiring =
        for score <- scores,
            score.valid_until != nil and Date.compare(score.valid_until, horizon) != :gt do
          recipients =
            supervisor_users(supervisors, users, score.employee_id) ++
              List.wrap(users[score.employee_id])

          item(
            "expiring_certificate",
            score.employee_id,
            score.skill_id,
            nil,
            score.valid_until,
            Enum.uniq(recipients)
          )
        end

      actions =
        Repo.all(
          from(a in Tenancy.scope_query(Action, scope),
            where: a.company_id == ^company_id and a.status in ^@pursued and a.due_on < ^as_of,
            order_by: [asc: a.id]
          )
        )
        |> Enum.map(fn action ->
          item(
            "overdue_action",
            action.employee_id,
            action.skill_id,
            action.id,
            action.due_on,
            List.wrap(users[action.owner_employee_id])
          )
        end)

      {:ok, overdue ++ expiring ++ actions ++ coverage_items(scope, company_id, coverage, as_of)}
    end
  end

  defp coverage_items(scope, company_id, coverage, as_of) do
    case Enum.reject(coverage, & &1.covered) do
      [] ->
        []

      gaps ->
        holders = Access.capability_holders(scope, company_id, @wide)
        for row <- gaps, do: item("coverage_gap", nil, row.skill_id, nil, as_of, holders)
    end
  end

  defp item(rule, employee_id, skill_id, action_id, due_on, recipients) do
    %{
      rule: rule,
      employee_id: employee_id,
      skill_id: skill_id,
      action_id: action_id,
      due_on: due_on,
      recipients: Enum.uniq(recipients)
    }
  end

  defp supervisor_users(supervisors, users, employee_id) do
    case Map.get(supervisors, employee_id) do
      nil -> []
      supervisor -> List.wrap(users[supervisor])
    end
  end

  defp deliver(scope, company_id, item, recipient, as_of, counts) do
    case claim(scope, company_id, item, recipient, as_of) do
      {:ok, row} ->
        case send_row(scope, row) do
          :sent -> Map.update!(counts, :sent, &(&1 + 1))
          :failed -> Map.update!(counts, :failed, &(&1 + 1))
        end

      :exists ->
        Map.update!(counts, :skipped, &(&1 + 1))
    end
  end

  # The unique key decides: only the run that inserts the row sends the message.
  defp claim(scope, company_id, item, recipient, as_of) do
    %Reminder{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      rule: item.rule,
      employee_id: item.employee_id,
      skill_id: item.skill_id,
      action_id: item.action_id,
      period_key: period_key(item.rule, as_of),
      recipient_user_id: recipient,
      due_on: item.due_on,
      state: "pending"
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:period_key, name: :people_skill_reminders_once)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{}} -> :exists
    end
  end

  defp send_row(scope, %Reminder{} = row) do
    skill =
      row.skill_id |> List.wrap() |> then(&Assessments.skills(scope, &1)) |> Map.get(row.skill_id)

    body = body(row.rule, (skill && skill.name) || "A skill", row.due_on)

    attrs = %{
      type: "people.skills.reminder",
      title: Map.fetch!(@titles, row.rule),
      body: body,
      url: url(row.rule),
      data: %{
        "rule" => row.rule,
        "skill_id" => row.skill_id,
        "employee_id" => row.employee_id,
        "action_id" => row.action_id,
        "due_on" => Date.to_iso8601(row.due_on),
        "title" => Map.fetch!(@titles, row.rule),
        "body" => body,
        "url" => url(row.rule)
      }
    }

    case User.send_notification(scope, row.recipient_user_id, attrs) do
      {:ok, _notification} ->
        row
        |> Ecto.Changeset.change(state: "sent", failure: nil, sent_at: Assessments.now())
        |> Repo.update!()

        :sent

      {:error, reason} ->
        row
        |> Ecto.Changeset.change(state: "failed", failure: failure(reason))
        |> Repo.update!()

        :failed
    end
  end

  defp body("overdue_reassessment", skill, date),
    do: "#{skill} reassessment was due on #{date}."

  defp body("expiring_certificate", skill, date), do: "#{skill} validity ends on #{date}."

  defp body("overdue_action", skill, date),
    do: "#{skill} development action was due on #{date}."

  defp body("coverage_gap", skill, date),
    do: "#{skill} has fewer qualified holders than the backup minimum as of #{date}."

  defp failure(:user_not_found), do: "recipient not found"
  defp failure(_reason), do: "notification could not be created"

  defp url("overdue_action"), do: "/people/skills/actions"
  defp url("coverage_gap"), do: "/people/skills/assessments"
  defp url(_rule), do: "/people/skills/my"

  ## Periods

  @doc false
  def period_key("coverage_gap", date), do: month_key(date)
  def period_key(_rule, date), do: week_key(date)

  defp week_key(date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp month_key(%Date{year: year, month: month}),
    do: "#{year}-M#{String.pad_leading(Integer.to_string(month), 2, "0")}"

  defp view(row),
    do: Map.take(row, [:id, :rule, :employee_id, :skill_id, :action_id, :due_on, :sent_at])
end
