defmodule Bilimbi.People.Organisation.PositionVersion do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_position_revisions" do
    field(:position_id, :integer)
    field(:version, :integer)
    field(:title, :string)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:position_id, :version, :title, :effective_from, :effective_to])
    |> validate_required([:position_id, :version, :title, :effective_from])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_interval()
    |> unique_constraint([:position_id, :version])
    |> exclusion_constraint(:effective_from, name: :people_position_revisions_no_overlap)
  end

  defp validate_interval(changeset) do
    from = get_field(changeset, :effective_from)
    to = get_field(changeset, :effective_to)

    if from && to && Date.compare(to, from) == :lt,
      do: add_error(changeset, :effective_to, "must be on or after the start"),
      else: changeset
  end
end
