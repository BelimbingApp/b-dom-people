defmodule Bilimbi.People.Training.Participation do
  @moduledoc """
  Confirmed session attendance and append-only corrections.
  Import keys identify one fact in a company; exact replay returns that fact,
  and a changed payload refuses reuse. Session locks serialize capacity checks.
  Evidence bytes and retention belong exclusively to Base Artifacts.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy, Artifacts}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.{Training, Workforce}
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Training.{ParticipationFact, Session, Evidence, DocumentOwner}

  defdelegate authorize(scope, company, capability), to: Training

  def record(scope, company, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, actor} <- authorize(scope, company, "people.training.records.manage"),
         true <-
           not is_nil(integer(attrs["session_id"])) and not is_nil(integer(attrs["employee_id"])) and
             is_binary(attrs["import_key"]) and is_binary(attrs["reason"]) do
      Repo.transaction(fn ->
        session_id = integer(attrs["session_id"])
        employee_id = integer(attrs["employee_id"])

        session =
          Repo.one(
            from(s in scoped(Session, scope, company),
              where: s.id == ^session_id,
              lock: "FOR UPDATE"
            )
          )

        if is_nil(session), do: Repo.rollback(:session_unavailable)

        replay =
          Repo.one(
            from(f in scoped(ParticipationFact, scope, company),
              where: f.import_key == ^(attrs["import_key"] || "")
            )
          )

        if replay do
          if replay.session_id == session_id and replay.employee_id == employee_id and
               replay.status == attrs["status"] and
               replay.reason == String.trim(attrs["reason"] || ""),
             do: view(replay),
             else: Repo.rollback(:import_conflict)
        else
          with {:ok, read} <- Workforce.employee(scope, company, employee_id),
               {:ok, _} <- ReadResult.require_current(read) do
            :ok
          else
            _ -> Repo.rollback(:employee_unavailable)
          end

          previous =
            Repo.one(
              from(f in scoped(ParticipationFact, scope, company),
                where: f.session_id == ^session_id and f.employee_id == ^employee_id,
                order_by: [desc: f.revision],
                limit: 1
              )
            )

          latest = latest_query(scope, company, session_id)

          occupied =
            Repo.aggregate(from(f in subquery(latest), where: f.status == "confirmed"), :count)

          if attrs["status"] == "confirmed" and
               (is_nil(previous) or previous.status != "confirmed") and
               occupied >= session.capacity,
             do: Repo.rollback(:attendance_capacity_exceeded)

          fact = %ParticipationFact{
            tenant_id: Scope.tenant_id(scope),
            company_id: company,
            actor_user_id: actor.user_id,
            impersonator_id: actor.impersonator_id,
            revision: if(previous, do: previous.revision + 1, else: 1)
          }

          attrs = Map.merge(attrs, %{"session_id" => session_id, "employee_id" => employee_id})

          case Repo.insert(ParticipationFact.changeset(fact, attrs)) do
            {:ok, fact} -> view(fact)
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)
    else
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  def sessions(scope, company) do
    with {:ok, _} <- authorize(scope, company, "people.training.records.view") do
      {:ok,
       Repo.all(
         from(s in scoped(Session, scope, company), order_by: [desc: s.starts_at], limit: 500)
       )
       |> Enum.map(&view/1)}
    end
  end

  def employees(scope, company) do
    with {:ok, _} <- authorize(scope, company, "people.training.records.manage"),
         {:ok, read} <- Workforce.employees(scope, company),
         {:ok, employees} <- ReadResult.require_current(read) do
      {:ok, Enum.map(employees, &%{id: integer(&1.reference.stable_id), name: &1.display_name})}
    end
  end

  def history(scope, company, session_id) do
    with {:ok, _} <- authorize(scope, company, "people.training.records.view"),
         id when not is_nil(id) <- integer(session_id) do
      {:ok,
       Repo.all(
         from(f in scoped(ParticipationFact, scope, company),
           where: f.session_id == ^id,
           order_by: [asc: f.employee_id, desc: f.revision]
         )
       )
       |> Enum.map(&view/1)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def fact(scope, company, id, capability \\ "people.training.records.view")

  def fact(scope, company, id, capability)
      when capability in [
             "people.training.records.view",
             "people.training.evidence.manage",
             "people.training.retention.manage"
           ] do
    with {:ok, _} <- authorize(scope, company, capability),
         parsed when not is_nil(parsed) <- integer(id),
         record when not is_nil(record) <-
           Repo.one(from(f in scoped(ParticipationFact, scope, company), where: f.id == ^parsed)) do
      %{id: record.id}
    end
  end

  def fact(_, _, _, _), do: {:error, :unauthorized}

  def attach(scope, company, fact_id, bytes) when is_binary(bytes) do
    with {:ok, actor} <- authorize(scope, company, "people.training.evidence.manage"),
         %{id: _} = fact <- fact(scope, company, fact_id, "people.training.evidence.manage"),
         true <- String.starts_with?(bytes, "%PDF-"),
         {:ok, document} <-
           Artifacts.put(
             scope,
             company,
             DocumentOwner,
             %{subject: to_string(fact.id), kind: "evidence"},
             bytes,
             "application/pdf"
           ) do
      row = %Evidence{
        tenant_id: Scope.tenant_id(scope),
        company_id: company,
        fact_id: fact.id,
        artifact_id: document.id,
        actor_user_id: actor.user_id,
        impersonator_id: actor.impersonator_id
      }

      case Repo.insert(Ecto.Changeset.change(row)) do
        {:ok, evidence} ->
          {:ok, view(evidence)}

        {:error, reason} ->
          Artifacts.delete(scope, company, DocumentOwner, document.id)
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_pdf}
      error -> error
    end
  end

  def evidence(scope, company, fact_id) do
    with {:ok, _} <- authorize(scope, company, "people.training.records.view"),
         id when not is_nil(id) <- integer(fact_id) do
      {:ok,
       Repo.all(
         from(e in scoped(Evidence, scope, company),
           where: e.fact_id == ^id,
           order_by: [asc: e.id]
         )
       )
       |> Enum.map(&view/1)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def read_evidence(scope, company, artifact_id) do
    with {:ok, _} <- authorize(scope, company, "people.training.records.view") do
      Artifacts.read(scope, company, DocumentOwner, artifact_id)
    end
  end

  def purge(scope, company), do: Artifacts.purge_expired(scope, company, DocumentOwner)
  def purge_holds(scope, company), do: Artifacts.list_purge_holds(scope, company, DocumentOwner)

  def retry_purge(scope, company, id),
    do: Artifacts.retry_purge(scope, company, DocumentOwner, id)

  defp latest_query(scope, company, session) do
    from(f in scoped(ParticipationFact, scope, company),
      where: f.session_id == ^session,
      distinct: f.employee_id,
      order_by: [asc: f.employee_id, desc: f.revision]
    )
  end

  defp scoped(schema, scope, company),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company)

  defp view(record), do: record |> Map.from_struct() |> Map.drop([:__meta__])

  defp integer(value) when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
    do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> integer(id)
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
