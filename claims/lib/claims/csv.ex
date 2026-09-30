defmodule Bilimbi.People.Claims.Csv do
  @moduledoc false

  # RFC 4180 output. Cells that a spreadsheet would read as a formula get a
  # leading apostrophe, so free text an employee typed cannot run on export.
  @formula_starts ["=", "+", "-", "@", "\t", "\r"]

  @doc "Encodes a header row and data rows, each a list of cell values."
  def encode(headers, rows) when is_list(headers) and is_list(rows) do
    Enum.map_join([headers | rows], "\r\n", fn row -> Enum.map_join(row, ",", &cell/1) end) <>
      "\r\n"
  end

  defp cell(nil), do: ""
  defp cell(%Date{} = date), do: Date.to_iso8601(date)
  defp cell(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)
  defp cell(%Decimal{} = amount), do: Decimal.to_string(amount, :normal)
  defp cell(value) when is_integer(value), do: Integer.to_string(value)

  defp cell(value) when is_binary(value) do
    value = if String.starts_with?(value, @formula_starts), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end
end
