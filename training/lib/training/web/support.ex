defmodule Bilimbi.People.Training.Web.Support do
  @moduledoc false
  alias Bilimbi.Core.Company

  def companies(current_scope, capability) do
    case Company.list_selectable_companies(current_scope.actor, capability) do
      {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
      _ -> []
    end
  end

  def company(companies, params) do
    case params["company_id"] do
      nil -> List.first(companies)
      id -> Enum.find(companies, &(to_string(&1.id) == id))
    end
  end

  def integer(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def message(:ambiguous_time),
    do: "That local time occurs twice. Choose a time outside the clock overlap."

  def message(:nonexistent_time),
    do: "That local time does not exist. Choose a time after the clock change."

  def message(:invalid_time_zone_or_time), do: "Enter valid local times and an IANA time zone."
  def message(:invalid_time_range), do: "The end must be after the start."
  def message(:capacity_exceeded), do: "Session capacity cannot exceed event capacity."
  def message(:course_unavailable), do: "Choose an active course in this company."
  def message(:event_unavailable), do: "Choose an event in this company."
  def message(:unauthorized), do: "You cannot do that for this company."
  def message(:not_found), do: "That record is not available to you."

  def message({:not_current, _}),
    do: "The workforce is not current. Try again when the connection is current."

  def message(:company_unavailable), do: "Choose an active company."

  def message(%Ecto.Changeset{}),
    do:
      "Check the entered values. Codes must be unique and capacity must be a positive whole number."

  def message(_), do: "That could not be completed. Refresh and try again."

  def page(records, params, key \\ "page") do
    size =
      case integer(params["perPage"] || "25") do
        n when n in [25, 50, 100, 300] -> n
        _ -> 25
      end

    total = length(records)
    pages = ceil(total / size)
    number = max(1, min(integer(params[key] || "1") || 1, max(pages, 1)))

    %{
      entries: Enum.slice(records, (number - 1) * size, size),
      page: number,
      page_size: size,
      total_entries: total,
      total_pages: pages
    }
  end
end
