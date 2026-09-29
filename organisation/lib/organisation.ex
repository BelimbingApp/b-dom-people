defmodule Bilimbi.People.Organisation do
  @moduledoc "Company-scoped positions, immutable versions and assignments."

  import Ecto.Query

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

  @doc "Appends a substantive, acting or concurrent assignment."
  def assign(%Scope{} = scope, company_id, position_id, attrs) when is_map(attrs) do
    employee_id = Map.get(attrs, :employee_id)

    with {:ok, _company} <- Workforce.company(scope, company_id),
         {:ok, _position} <- get_position(company_id, position_id),
         {:ok, _employee} <- Workforce.employee(scope, company_id, employee_id) do
      %PositionAssignment{}
      |> PositionAssignment.changeset(Map.put(attrs, :position_id, position_id))
      |> Repo.insert()
    end
  end

  @doc "Returns one bounded page of positions as of a day, including vacancies."
  def positions(%Scope{} = scope, company_id, as_of \\ Date.utc_today(), options \\ []) do
    with {:ok, _company} <- Workforce.company(scope, company_id),
         :ok <- validate_date(as_of),
         {:ok, page, size} <- page_options(options),
         {:ok, employees} <- Workforce.employees(scope, company_id) do
      offset = (page - 1) * size

      rows =
        from(position in Position,
          where: position.company_id == ^company_id,
          order_by: [asc: position.id],
          limit: ^size,
          offset: ^offset
        )
        |> Repo.all()

      ids = Enum.map(rows, & &1.id)
      holder_ids = Enum.map(employees, &String.to_integer(&1.reference.stable_id))
      versions = effective_versions(ids, as_of)
      {assignments, truncated_at_id} = effective_assignments(ids, holder_ids, as_of)
      occupied = substantive_position_ids(ids, holder_ids, as_of)

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

  defp effective_assignments([], _holder_ids, _day), do: {%{}, nil}

  defp effective_assignments(ids, holder_ids, day) do
    rows =
      from(assignment in PositionAssignment,
        where:
          assignment.position_id in ^ids and assignment.employee_id in ^holder_ids and
            assignment.effective_from <= ^day and
            (is_nil(assignment.effective_to) or assignment.effective_to >= ^day),
        order_by: [asc: assignment.position_id, asc: assignment.id],
        limit: @assignment_limit + 1
      )
      |> Repo.all()

    {visible, truncated_at_id} =
      case Enum.split(rows, @assignment_limit) do
        {visible, [first_omitted | _]} -> {visible, first_omitted.position_id}
        {visible, []} -> {visible, nil}
      end

    values =
      Enum.group_by(visible, & &1.position_id, fn assignment ->
        %{employee_reference: reference(:employee, assignment.employee_id), kind: assignment.kind}
      end)

    {values, truncated_at_id}
  end

  defp substantive_position_ids([], _holder_ids, _day), do: MapSet.new()

  defp substantive_position_ids(ids, holder_ids, day) do
    from(assignment in PositionAssignment,
      where:
        assignment.position_id in ^ids and assignment.employee_id in ^holder_ids and
          assignment.kind == "substantive" and
          assignment.effective_from <= ^day and
          (is_nil(assignment.effective_to) or assignment.effective_to >= ^day),
      select: assignment.position_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

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
