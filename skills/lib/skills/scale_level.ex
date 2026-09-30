defmodule Bilimbi.People.Skills.ScaleLevel do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skill_scale_levels" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:scale_id, :integer)
    field(:level, :integer)
    field(:name, :string)
    field(:anchor, :string)
    field(:authority, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(level, attrs) do
    level
    |> cast(attrs, [:level, :name, :anchor, :authority])
    |> update_change(:name, &String.trim/1)
    |> update_change(:anchor, &String.trim/1)
    |> update_change(:authority, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :scale_id, :level, :name, :anchor, :authority])
    |> validate_number(:level, greater_than_or_equal_to: 0, less_than_or_equal_to: 20)
    |> validate_length(:name, max: 100)
    |> validate_length(:anchor, max: 2000)
    |> validate_length(:authority, max: 2000)
    |> unique_constraint([:scale_id, :level], name: :people_skill_scale_levels_scale_level_unique)
  end
end
