defmodule Bilimbi.People.Payroll.Replay do
  @moduledoc "Deterministic decimal replay of frozen rates and accepted contributions."

  # No ambient Decimal context, floats, current settings, or live source reads.
  # Six-place rates multiplied by six-place units retain twelve-place precision.
  def calculate(setup, contributions) do
    Decimal.Context.with(%Decimal.Context{precision: 60}, fn ->
      lines =
        contributions
        |> Enum.sort_by(& &1["source_key"])
        |> Enum.map(fn input ->
          item = Enum.find(setup["items"], &(&1["id"] == input["item_id"]))
          amount = Decimal.mult(Decimal.new(item["amount"]), Decimal.new(input["units"]))

          Map.merge(input, %{
            "item_code" => item["code"],
            "rate" => item["amount"],
            "amount" => Decimal.to_string(amount, :normal)
          })
        end)

      totals =
        lines
        |> Enum.group_by(& &1["employee_id"])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {employee, rows} ->
          sums = Map.new(~w(earning deduction employer), &{&1, sum(rows, &1)})
          net = Decimal.sub(Decimal.new(sums["earning"]), Decimal.new(sums["deduction"]))
          Map.merge(sums, %{"employee_id" => employee, "net" => Decimal.to_string(net, :normal)})
        end)

      %{"version" => 1, "lines" => lines, "totals" => totals}
    end)
  end

  @doc "SHA-256 of the snapshot's canonical JSON with sorted object keys."
  def digest(snapshot),
    do: :crypto.hash(:sha256, canonical(snapshot)) |> Base.encode16(case: :lower)

  defp canonical(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ?:, canonical(value)] end)

    [?{, Enum.intersperse(pairs, ?,), ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &canonical/1), ?,), ?]]

  defp canonical(value), do: JSON.encode!(value)

  defp sum(rows, direction) do
    rows
    |> Enum.filter(&(&1["direction"] == direction))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["amount"]), &2))
    |> Decimal.to_string(:normal)
  end
end
