defmodule Bilimbi.People.Organisation.Position do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_positions" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:parent_id, :integer)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, [:company_id, :code, :parent_id])
    |> validate_required([:company_id, :code])
    |> validate_length(:code, min: 1, max: 255)
    |> unique_constraint([:company_id, :code])
    |> check_constraint(:parent_id, name: :people_positions_not_own_parent)
    |> foreign_key_constraint(:parent_id, name: :people_positions_parent_company_fk)
  end
end
