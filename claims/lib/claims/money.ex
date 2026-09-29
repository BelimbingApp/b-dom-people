defmodule Bilimbi.People.Claims.Money do
  @moduledoc false
  import Ecto.Changeset

  # Columns are numeric(14, 2): twelve integer digits and two minor-unit digits.
  @ceiling Decimal.new("1000000000000")

  @doc "Validates a two-decimal amount below the column ceiling."
  def validate_amount(changeset, field, min: min) do
    validate_change(changeset, field, fn ^field, amount ->
      cond do
        Decimal.scale(Decimal.normalize(amount)) > 2 ->
          [{field, "must have at most two decimal places"}]

        min == :positive and not Decimal.gt?(amount, 0) ->
          [{field, "must be greater than zero"}]

        min == :zero and Decimal.lt?(amount, 0) ->
          [{field, "must not be negative"}]

        not Decimal.lt?(amount, @ceiling) ->
          [{field, "is too large"}]

        true ->
          []
      end
    end)
  end
end
