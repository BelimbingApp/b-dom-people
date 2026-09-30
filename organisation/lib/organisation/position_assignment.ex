defmodule Bilimbi.People.Organisation.PositionAssignment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_position_placements" do
    field(:position_id, :integer)
    field(:employee_id, :integer)
    field(:kind, :string)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:position_id, :employee_id, :kind, :effective_from, :effective_to])
    |> validate_required([:position_id, :employee_id, :kind, :effective_from])
    |> validate_inclusion(:kind, ~w(substantive acting concurrent))
    |> validate_interval()
    |> exclusion_constraint(:effective_from, name: :people_position_placements_one_substantive)
  end

  def end_changeset(assignment, effective_to) do
    assignment
    |> cast(%{effective_to: effective_to}, [:effective_to])
    |> validate_required([:effective_to])
    |> validate_interval()
    |> validate_shortened(assignment.effective_to)
  end

  defp validate_shortened(changeset, nil), do: changeset

  defp validate_shortened(changeset, previous) do
    to = get_field(changeset, :effective_to)

    if to && Date.compare(to, previous) != :lt,
      do: add_error(changeset, :effective_to, "must be before the current end"),
      else: changeset
  end

  defp validate_interval(changeset) do
    from = get_field(changeset, :effective_from)
    to = get_field(changeset, :effective_to)

    if from && to && Date.compare(to, from) == :lt,
      do: add_error(changeset, :effective_to, "must be on or after the start"),
      else: changeset
  end
end
