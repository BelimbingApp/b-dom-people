defmodule Bilimbi.People.Organisation do
  @moduledoc "Company-scoped positions, immutable versions and assignments."

  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Audit.Context
  alias Bilimbi.Base.Authz.Actor
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Organisation.{Position, PositionAssignment, PositionVersion}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Position, as: WorkforcePosition
  alias Bilimbi.People.Workforce.Reference

  @page_size 50
  @max_page_size 100
  @assignment_limit 500
  @manage_capability "people.organisation.manage"

  @doc "Creates a stable position identity in one live workforce company."
  def create_position(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- Workforce.company(scope, company_id),
         {:ok, parent_id} <- parent_id(company_id, Map.get(attrs, :parent_id)) do
      code = attrs |> Map.get(:code) |> normalize_text()

      %Position{}
      |> Position.changeset(%{company_id: company_id, code: code, parent_id: parent_id})
      |> Repo.insert()
    end
  end

  @doc "Moves a position below another position after checking company and cycles."
  def set_parent(%Scope{} = scope, company_id, position_id, new_parent_id) do
    with {:ok, _company} <- Workforce.company(scope, company_id) do
      case Repo.transaction(fn ->
             with {:ok, _locked} <- Company.lock_live_company(scope, company_id),
                  {:ok, position} <- get_position(company_id, position_id),
                  {:ok, parent_id} <- parent_id(company_id, new_parent_id),
                  :ok <- reject_cycle(company_id, position.id, parent_id) do
               position |> Position.changeset(%{parent_id: parent_id}) |> Repo.update()
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Appends a version; dates are inclusive and existing versions never change."
  def record_version(%Scope{} = scope, company_id, position_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- Workforce.company(scope, company_id),
         {:ok, _position} <- get_position(company_id, position_id) do
      %PositionVersion{}
      |> PositionVersion.changeset(Map.put(attrs, :position_id, position_id))
      |> Repo.insert()
    end
  end

  @doc """
  Appends a substantive, acting or concurrent assignment for a working employee.

  A new substantive assignment ends an earlier substantive holder who is no
  longer working on the day before it starts, and records that release.
  """
  def assign(%Scope{} = scope, company_id, position_id, attrs) when is_map(attrs) do
    employee_id = Map.get(attrs, :employee_id)

    with {:ok, _company} <- Workforce.company(scope, company_id),
         {:ok, _position} <- get_position(company_id, position_id),
         {:ok, _employee} <- Workforce.employee(scope, company_id, employee_id) do
      changeset =
        PositionAssignment.changeset(
          %PositionAssignment{},
          Map.put(attrs, :position_id, position_id)
        )

      transact(fn ->
        with {:ok, _locked} <- Company.lock_live_company(scope, company_id),
             :ok <- release_seat(scope, company_id, changeset) do
          Repo.insert(changeset)
        end
      end)
    end
  end

  @doc "Ends one assignment on an inclusive day, only ever earlier, and records the action."
  def end_assignment(%Actor{} = actor, company_id, assignment_id, effective_to) do
    with {:ok, _company} <-
           Company.authorize_company_target(actor, company_id, @manage_capability),
         {:ok, _company} <- Workforce.company(actor.scope, company_id) do
      transact(fn ->
        with {:ok, _locked} <- Company.lock_live_company(actor.scope, company_id),
             {:ok, assignment} <- get_assignment(company_id, assignment_id) do
          end_placement(
            actor.scope,
            company_id,
            assignment,
            effective_to,
            {Actor.principal_type(actor), actor.id},
            "people.organisation.assignment_ended"
          )
        end
      end)
    end
  end

  @doc "Returns one bounded page of positions as of a day, including vacancies."
  def positions(%Scope{} = scope, company_id, as_of \\ Date.utc_today(), options \\ []) do
    with {:ok, _company} <- Workforce.company(scope, company_id),
         :ok <- validate_date(as_of),
         {:ok, page, size} <- page_options(options),
         rows = page_rows(company_id, page, size),
         ids = Enum.map(rows, & &1.id),
         {placements, truncated_at_id} = effective_assignments(ids, as_of),
         substantive = substantive_assignments(ids, as_of),
         {:ok, working} <- working_ids(scope, company_id, placements ++ substantive) do
      versions = effective_versions(ids, as_of)

      assignments =
        placements
        |> Enum.filter(&MapSet.member?(working, &1.employee_id))
        |> Enum.group_by(& &1.position_id, &project_assignment/1)

      occupied =
        for assignment <- substantive,
            MapSet.member?(working, assignment.employee_id),
            into: MapSet.new(),
            do: assignment.position_id

      {:ok,
       Enum.map(rows, fn position ->
         version = Map.get(versions, position.id)
         holders = Map.get(assignments, position.id, [])

         %WorkforcePosition{
           reference: reference(:position, position.id),
           company_reference: reference(:company, company_id),
           platform_company_id: company_id,
           workforce_company_id: company_id,
           code: position.code,
           parent_reference: position.parent_id && reference(:position, position.parent_id),
           title: version && version.title,
           version: version && version.version,
           assignments: holders,
           assignments_incomplete?:
             not is_nil(truncated_at_id) and position.id >= truncated_at_id,
           vacant?: not MapSet.member?(occupied, position.id)
         }
       end)}
    end
  end

  @doc "Counts positions for a validated company so an explorer can page them."
  def count_positions(%Scope{} = scope, company_id) do
    with {:ok, _company} <- Workforce.company(scope, company_id) do
      {:ok, Repo.aggregate(from(p in Position, where: p.company_id == ^company_id), :count)}
    end
  end

  defp effective_versions([], _day), do: %{}

  defp effective_versions(ids, day) do
    from(version in PositionVersion,
      where:
        version.position_id in ^ids and version.effective_from <= ^day and
          (is_nil(version.effective_to) or version.effective_to >= ^day)
    )
    |> Repo.all()
    |> Map.new(&{&1.position_id, &1})
  end

  defp page_rows(company_id, page, size) do
    from(position in Position,
      where: position.company_id == ^company_id,
      order_by: [asc: position.id],
      limit: ^size,
      offset: ^((page - 1) * size)
    )
    |> Repo.all()
  end

  defp working_ids(scope, company_id, assignments) do
    ids = assignments |> Enum.map(& &1.employee_id) |> Enum.uniq()

    with {:ok, employees} <- Workforce.employees_by_ids(scope, company_id, ids) do
      {:ok, MapSet.new(employees, &String.to_integer(&1.reference.stable_id))}
    end
  end

  defp project_assignment(assignment) do
    %{
      reference: reference(:assignment, assignment.id),
      employee_reference: reference(:employee, assignment.employee_id),
      kind: assignment.kind
    }
  end

  defp effective_assignments([], _day), do: {[], nil}

  defp effective_assignments(ids, day) do
    rows =
      from(assignment in PositionAssignment,
        where:
          assignment.position_id in ^ids and assignment.effective_from <= ^day and
            (is_nil(assignment.effective_to) or assignment.effective_to >= ^day),
        order_by: [asc: assignment.position_id, asc: assignment.id],
        limit: @assignment_limit + 1
      )
      |> Repo.all()

    case Enum.split(rows, @assignment_limit) do
      {visible, [first_omitted | _]} -> {visible, first_omitted.position_id}
      {visible, []} -> {visible, nil}
    end
  end

  defp substantive_assignments([], _day), do: []

  defp substantive_assignments(ids, day) do
    from(assignment in PositionAssignment,
      where:
        assignment.position_id in ^ids and assignment.kind == "substantive" and
          assignment.effective_from <= ^day and
          (is_nil(assignment.effective_to) or assignment.effective_to >= ^day)
    )
    |> Repo.all()
  end

  defp release_seat(scope, company_id, %Ecto.Changeset{valid?: true} = changeset) do
    if Ecto.Changeset.get_field(changeset, :kind) == "substantive" do
      start = Ecto.Changeset.get_field(changeset, :effective_from)
      position_id = Ecto.Changeset.get_field(changeset, :position_id)
      context = Context.get()

      from(assignment in PositionAssignment,
        where:
          assignment.position_id == ^position_id and assignment.kind == "substantive" and
            assignment.effective_from < ^start and
            (is_nil(assignment.effective_to) or assignment.effective_to >= ^start),
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Enum.reject(&match?({:ok, _}, Workforce.employee(scope, company_id, &1.employee_id)))
      |> Enum.reduce_while(:ok, fn assignment, :ok ->
        case end_placement(
               scope,
               company_id,
               assignment,
               Date.add(start, -1),
               {context.actor_type, context.actor_id},
               "people.organisation.assignment_released"
             ) do
          {:ok, _ended} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp release_seat(_scope, _company_id, _changeset), do: :ok

  defp end_placement(scope, company_id, assignment, effective_to, {actor_type, actor_id}, event) do
    with {:ok, ended} <-
           assignment |> PositionAssignment.end_changeset(effective_to) |> Repo.update(),
         {:ok, _action} <-
           Audit.record_action(scope, %{
             company_id: company_id,
             actor_type: actor_type,
             actor_id: actor_id,
             event: event,
             payload: %{
               "assignment_id" => ended.id,
               "position_id" => ended.position_id,
               "employee_id" => ended.employee_id,
               "previous_effective_to" =>
                 assignment.effective_to && Date.to_iso8601(assignment.effective_to),
               "effective_to" => Date.to_iso8601(ended.effective_to)
             },
             occurred_at: NaiveDateTime.utc_now()
           }) do
      {:ok, ended}
    end
  end

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp get_assignment(company_id, id) when is_integer(id) and id > 0 do
    query =
      from(assignment in PositionAssignment,
        join: position in Position,
        on: position.id == assignment.position_id,
        where: assignment.id == ^id and position.company_id == ^company_id,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      assignment -> {:ok, assignment}
    end
  end

  defp get_assignment(_company_id, _id), do: {:error, :not_found}

  defp get_position(company_id, id) when is_integer(id) and id > 0 do
    case Repo.get_by(Position, id: id, company_id: company_id) do
      nil -> {:error, :not_found}
      position -> {:ok, position}
    end
  end

  defp get_position(_company_id, _id), do: {:error, :not_found}

  defp parent_id(_company_id, nil), do: {:ok, nil}

  defp parent_id(company_id, id) do
    case get_position(company_id, id) do
      {:ok, position} -> {:ok, position.id}
      error -> error
    end
  end

  defp reject_cycle(_company_id, _id, nil), do: :ok

  defp reject_cycle(company_id, id, parent_id) do
    reject_cycle(company_id, id, parent_id, MapSet.new())
  end

  defp reject_cycle(_company_id, _id, nil, _seen), do: :ok

  defp reject_cycle(company_id, id, parent_id, seen) do
    if MapSet.member?(seen, parent_id) do
      {:error, :cycle}
    else
      reject_cycle_step(company_id, id, parent_id, MapSet.put(seen, parent_id))
    end
  end

  defp reject_cycle_step(company_id, id, parent_id, seen) do
    case Repo.get_by(Position, id: parent_id, company_id: company_id) do
      nil -> {:error, :not_found}
      %{id: ^id} -> {:error, :cycle}
      %{parent_id: nil} -> :ok
      %{parent_id: ancestor_id} -> reject_cycle(company_id, id, ancestor_id, seen)
    end
  end

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(_value), do: nil

  defp validate_date(%Date{}), do: :ok
  defp validate_date(_), do: {:error, :invalid_date}

  defp page_options(options) when is_list(options) do
    page = Keyword.get(options, :page, 1)
    size = Keyword.get(options, :page_size, @page_size)

    if is_integer(page) and page > 0 and is_integer(size) and size > 0 and
         size <= @max_page_size,
       do: {:ok, page, size},
       else: {:error, :invalid_options}
  end

  defp page_options(_), do: {:error, :invalid_options}

  defp reference(type, id),
    do: %Reference{source_id: Workforce.source_id(), type: type, stable_id: Integer.to_string(id)}
end
