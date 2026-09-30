defmodule Bilimbi.People.Attendance.Adjustments do
  @moduledoc false
  # Missing-punch requests. An employee submits for their own linked employee;
  # an approver who is neither the requester nor that employee decides. Only an
  # approval writes a clock event, through the normal ingestion path.
  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.{Access, AdjustmentRequest}

  @self_limit 20
  @queue_limit 200

  def submit_adjustment(%Scope{} = scope, company_id, actor, attrs) when is_map(attrs) do
    with {:ok, employee_id} <- Access.self_employee(scope, company_id, actor),
         {:ok, rules} <- Attendance.rules(scope, company_id),
         {:ok, proposed_at} <- proposed_at(field(attrs, :local_at), rules.timezone),
         {:ok, on_date} <- Attendance.local_date(proposed_at, rules.timezone),
         :ok <- within_window(proposed_at, on_date, rules) do
      request = %AdjustmentRequest{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        employee_id: employee_id,
        requested_by_user_id: actor.id
      }

      changeset =
        AdjustmentRequest.changeset(request, %{
          request_key: field(attrs, :request_key),
          event_type: field(attrs, :event_type),
          reason: field(attrs, :reason) || "",
          proposed_at: proposed_at,
          on_date: on_date,
          timezone: rules.timezone
        })

      Access.transact(fn -> insert_request(scope, company_id, changeset) end)
    end
  end

  def self_adjustments(%Scope{} = scope, company_id, actor) do
    with {:ok, employee_id} <- Access.self_employee(scope, company_id, actor) do
      {:ok,
       Repo.all(
         from(r in Tenancy.scope_query(AdjustmentRequest, scope),
           where: r.company_id == ^company_id and r.employee_id == ^employee_id,
           order_by: [desc: r.inserted_at, desc: r.id],
           limit: @self_limit
         )
       )}
    end
  end

  def cancel_adjustment(%Scope{} = scope, company_id, actor, request_id) do
    with {:ok, employee_id} <- Access.self_employee(scope, company_id, actor) do
      Access.transact(fn ->
        case locked_request(scope, company_id, request_id) do
          %AdjustmentRequest{employee_id: ^employee_id, status: "pending"} = request ->
            request
            |> AdjustmentRequest.decision_changeset("cancelled", actor.id, nil)
            |> Repo.update()

          %AdjustmentRequest{employee_id: ^employee_id} ->
            {:error, :not_pending}

          _ ->
            {:error, :not_found}
        end
      end)
    end
  end

  @doc "Pending requests, oldest proposed time first, with the employee's name."
  def pending_adjustments(%Scope{} = scope, company_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      requests =
        Repo.all(
          from(r in Tenancy.scope_query(AdjustmentRequest, scope),
            where: r.company_id == ^company_id and r.status == "pending",
            order_by: [asc: r.proposed_at, asc: r.id],
            limit: @queue_limit
          )
        )

      ids = requests |> Enum.map(& &1.employee_id) |> Enum.uniq()

      with {:ok, employees} <- Access.employees_by_ids(scope, company_id, ids) do
        names =
          Map.new(employees, fn employee ->
            {String.to_integer(employee.reference.stable_id),
             "#{employee.display_name} (#{employee.employee_number})"}
          end)

        {:ok,
         Enum.map(requests, fn request ->
           %{request: request, employee_name: Map.get(names, request.employee_id)}
         end)}
      end
    end
  end

  @doc """
  Approves or rejects a pending request. Refuses the requester and the
  request's own employee; a rejection needs a note.
  """
  def decide_adjustment(%Scope{} = scope, company_id, actor, request_id, decision, note)
      when decision in [:approve, :reject] do
    note = if is_binary(note), do: String.trim(note), else: nil
    note = if note == "", do: nil, else: note

    with {:ok, _company} <- Access.current_company(scope, company_id),
         :ok <- note_given(decision, note) do
      Access.transact(fn ->
        with %AdjustmentRequest{status: "pending"} = request <-
               locked_request(scope, company_id, request_id),
             :ok <- independent_approver(scope, company_id, actor, request),
             {:ok, decided} <- apply_decision(scope, company_id, actor, request, decision, note),
             {:ok, _action} <- audit(scope, actor, decided) do
          {:ok, decided}
        else
          %AdjustmentRequest{} -> {:error, :not_pending}
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  def decide_adjustment(%Scope{}, _, _, _, _, _), do: {:error, :invalid_decision}

  defp apply_decision(_scope, _company_id, actor, request, :reject, note) do
    request |> AdjustmentRequest.decision_changeset("rejected", actor.id, note) |> Repo.update()
  end

  defp apply_decision(scope, company_id, actor, request, :approve, note) do
    with {:ok, _employee} <- Access.current_employee(scope, company_id, request.employee_id),
         {:ok, event} <-
           Attendance.record_approved_adjustment(scope, company_id, request.employee_id, %{
             event_key: "request:#{request.id}",
             event_type: request.event_type,
             source: "adjustment",
             occurred_at: request.proposed_at,
             actor_user_id: actor.id
           }) do
      request
      |> AdjustmentRequest.decision_changeset("approved", actor.id, note, event.id)
      |> Repo.update()
    else
      {:error, :not_found} -> {:error, :employee_unavailable}
      {:error, :not_current} -> {:error, :employee_unavailable}
      error -> error
    end
  end

  defp independent_approver(scope, company_id, actor, request) do
    cond do
      actor.id == request.requested_by_user_id ->
        {:error, :self_approval}

      Access.linked_employee_id(scope, company_id, actor) == {:ok, request.employee_id} ->
        {:error, :self_approval}

      true ->
        :ok
    end
  end

  defp note_given(:reject, nil), do: {:error, :note_required}

  defp note_given(_, note) when is_binary(note) and byte_size(note) > 500,
    do: {:error, :note_too_long}

  defp note_given(_, _), do: :ok

  defp audit(scope, actor, request) do
    Audit.record_action(scope, %{
      company_id: request.company_id,
      actor_type: Atom.to_string(actor.type),
      actor_id: actor.id,
      event: "people.attendance.adjustment_#{request.status}",
      payload: %{
        "request_id" => request.id,
        "employee_id" => request.employee_id,
        "event_type" => request.event_type,
        "proposed_at" => DateTime.to_iso8601(request.proposed_at),
        "applied_clock_event_id" => request.applied_clock_event_id
      },
      occurred_at: NaiveDateTime.utc_now()
    })
  end

  defp insert_request(scope, company_id, changeset) do
    key = Ecto.Changeset.get_field(changeset, :request_key)

    case key && find_by_key(scope, company_id, key) do
      %AdjustmentRequest{} = existing -> replay(existing, changeset)
      _ -> insert_new(scope, company_id, changeset)
    end
  end

  defp insert_new(scope, company_id, changeset) do
    fields = Ecto.Changeset.apply_changes(changeset)

    duplicate? =
      changeset.valid? and
        Repo.exists?(
          from(r in Tenancy.scope_query(AdjustmentRequest, scope),
            where:
              r.company_id == ^company_id and r.employee_id == ^fields.employee_id and
                r.event_type == ^fields.event_type and r.proposed_at == ^fields.proposed_at and
                r.status in ["pending", "approved"]
          )
        )

    if duplicate? do
      {:error, :duplicate_request}
    else
      case Repo.insert(changeset, mode: :savepoint) do
        {:ok, request} ->
          {:ok, request}

        {:error, failed} ->
          if Keyword.has_key?(failed.errors, :company_id),
            do: replay(find_by_key(scope, company_id, fields.request_key), changeset),
            else: {:error, failed}
      end
    end
  end

  defp replay(%AdjustmentRequest{} = existing, changeset) do
    wanted = Ecto.Changeset.apply_changes(changeset)

    if existing.employee_id == wanted.employee_id and existing.event_type == wanted.event_type and
         existing.proposed_at == wanted.proposed_at,
       do: {:ok, existing},
       else: {:error, :request_key_conflict}
  end

  defp replay(nil, _changeset), do: {:error, :request_key_conflict}

  defp find_by_key(scope, company_id, key) do
    Repo.one(
      from(r in Tenancy.scope_query(AdjustmentRequest, scope),
        where: r.company_id == ^company_id and r.request_key == ^key
      )
    )
  end

  defp locked_request(scope, company_id, id) when is_integer(id) do
    Repo.one(
      from(r in Tenancy.scope_query(AdjustmentRequest, scope),
        where: r.company_id == ^company_id and r.id == ^id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_request(_, _, _), do: nil

  defp proposed_at(%NaiveDateTime{} = local, timezone) do
    case DateTime.from_naive(local, timezone, BaseDateTime.time_zone_database()) do
      {:ok, at} ->
        {:ok,
         at
         |> DateTime.shift_zone!("Etc/UTC", BaseDateTime.time_zone_database())
         |> DateTime.truncate(:second)}

      _ ->
        {:error, :invalid_time}
    end
  end

  defp proposed_at(local, timezone) when is_binary(local) do
    value = if String.length(local) == 16, do: local <> ":00", else: local

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> proposed_at(naive, timezone)
      _ -> {:error, :invalid_time}
    end
  end

  defp proposed_at(_, _), do: {:error, :invalid_time}

  defp within_window(proposed_at, on_date, rules) do
    {:ok, today} = Attendance.local_date(DateTime.utc_now(), rules.timezone)

    cond do
      DateTime.compare(proposed_at, DateTime.utc_now()) == :gt -> {:error, :future_time}
      Date.diff(today, on_date) >= rules.adjustment_window_days -> {:error, :outside_window}
      true -> :ok
    end
  end

  defp field(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
