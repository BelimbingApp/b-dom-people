defmodule Bilimbi.People.Attendance.Locations do
  @moduledoc false
  # Operator-managed clocking locations and the point-in-location check.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Attendance.{Access, ClockingLocation}

  def list_clocking_locations(%Scope{} = scope, company_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(l in Tenancy.scope_query(ClockingLocation, scope),
           where: l.company_id == ^company_id,
           order_by: [asc: l.status, asc: l.code]
         )
       )}
    end
  end

  def create_clocking_location(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      %ClockingLocation{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> ClockingLocation.changeset(attrs)
      |> Repo.insert()
    end
  end

  def set_clocking_location_status(%Scope{} = scope, company_id, location_id, status)
      when status in ~w(active retired) do
    with {:ok, _company} <- Access.current_company(scope, company_id),
         %ClockingLocation{} = location <- get(scope, company_id, location_id) do
      location |> ClockingLocation.status_changeset(status) |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def set_clocking_location_status(%Scope{}, _, _, _), do: {:error, :invalid_status}

  @doc "The nearest active location whose radius contains the point, or `:none`."
  def locate(%Scope{} = scope, company_id, latitude, longitude) do
    from(l in Tenancy.scope_query(ClockingLocation, scope),
      where: l.company_id == ^company_id and l.status == "active"
    )
    |> Repo.all()
    |> Enum.map(&{&1, ClockingLocation.distance_meters(&1, latitude, longitude)})
    |> Enum.filter(fn {location, distance} -> distance <= location.radius_meters end)
    |> Enum.min_by(&elem(&1, 1), fn -> nil end)
    |> case do
      {location, _distance} -> {:ok, location}
      nil -> :none
    end
  end

  defp get(scope, company_id, id) when is_integer(id) do
    Repo.one(
      from(l in Tenancy.scope_query(ClockingLocation, scope),
        where: l.company_id == ^company_id and l.id == ^id
      )
    )
  end

  defp get(_, _, _), do: nil
end
