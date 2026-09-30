defmodule Bilimbi.People.Skills.Code do
  @moduledoc false
  import Ecto.Changeset

  @doc "Codes are stable lowercase identifiers chosen by the company."
  def validate(changeset, field) do
    changeset
    |> validate_length(field, min: 1, max: 80)
    |> validate_format(field, ~r/^[a-z0-9][a-z0-9._-]*$/)
  end
end
