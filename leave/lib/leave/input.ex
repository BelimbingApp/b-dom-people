defmodule Bilimbi.People.Leave.Input do
  @moduledoc false
  # Parsing shared by leave facade operations.

  @max_quantity Decimal.new("9999.99")

  def field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  def parse_date(%Date{} = date), do: {:ok, date}

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  def parse_date(_), do: {:error, :invalid_date}

  def parse_quantity(%Decimal{} = value), do: bounded_quantity(value)
  def parse_quantity(value) when is_integer(value), do: bounded_quantity(Decimal.new(value))

  def parse_quantity(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> bounded_quantity(decimal)
      _ -> {:error, :invalid_quantity}
    end
  end

  def parse_quantity(_), do: {:error, :invalid_quantity}

  # Quantities are hundredths of the type's unit; finer values are refused
  # rather than rounded.
  defp bounded_quantity(decimal) do
    if Decimal.inf?(decimal) or Decimal.nan?(decimal) or
         Decimal.gt?(Decimal.abs(decimal), @max_quantity) or
         not Decimal.eq?(Decimal.round(decimal, 2), decimal),
       do: {:error, :invalid_quantity},
       else: {:ok, Decimal.round(decimal, 2)}
  end

  @doc "A trimmed optional text of at most `max` characters; blank is nil."
  def optional_text(nil, _max), do: {:ok, nil}

  def optional_text(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> if String.length(text) <= max, do: {:ok, text}, else: {:error, :invalid_text}
    end
  end

  def optional_text(_, _), do: {:error, :invalid_text}
end
