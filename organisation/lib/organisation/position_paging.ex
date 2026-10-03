defmodule Bilimbi.People.Organisation.PositionPaging do
  @moduledoc false

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Organisation.Position

  # Cursor contents are an opaque transport format, not an authorization token.
  # Organisation validates the live company before every read, including resumes.
  def read(scope, company_id, as_of, size, cursor) do
    boundary = {Scope.tenant_id(scope), to_string(company_id), Date.to_iso8601(as_of)}

    with {:ok, last_id, high_water_id} <- bounds(cursor, boundary, company_id) do
      rows =
        from(p in Position,
          where: p.company_id == ^company_id and p.id > ^last_id and p.id <= ^high_water_id,
          order_by: [asc: p.id],
          limit: ^(size + 1)
        )
        |> Repo.all()

      {positions, remaining} = Enum.split(rows, size)

      next_cursor =
        if remaining != [],
          do: encode(boundary, List.last(positions).id, high_water_id)

      {:ok, positions, %{next_cursor: next_cursor, high_water_id: high_water_id}}
    end
  end

  defp bounds(nil, _boundary, company_id) do
    high_water_id =
      from(p in Position, where: p.company_id == ^company_id, select: max(p.id))
      |> Repo.one()

    {:ok, 0, high_water_id || 0}
  end

  defp bounds(cursor, {tenant_id, company_id, day}, _company_id)
       when is_binary(cursor) and byte_size(cursor) <= 256 do
    with {:ok, payload} <- Base.url_decode64(cursor, padding: false),
         ["1", tenant, ^company_id, ^day, last, high] <- String.split(payload, ":"),
         {^tenant_id, ""} <- Integer.parse(tenant),
         {last_id, ""} when last_id > 0 <- Integer.parse(last),
         {high_water_id, ""}
         when high_water_id >= last_id and high_water_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(high) do
      {:ok, last_id, high_water_id}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp bounds(_cursor, _boundary, _company_id), do: {:error, :invalid_cursor}

  defp encode({tenant_id, company_id, day}, last_id, high_water_id) do
    ["1", tenant_id, company_id, day, last_id, high_water_id]
    |> Enum.join(":")
    |> Base.url_encode64(padding: false)
  end
end
