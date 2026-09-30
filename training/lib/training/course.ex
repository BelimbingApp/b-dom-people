defmodule Bilimbi.People.Training.Course do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_courses" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:description, :string)
    field(:active, :boolean)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:code, :name, :description, :active])
    |> validate_required([:tenant_id, :company_id, :actor_user_id, :code, :name, :active])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> validate_length(:code, max: 80)
    |> validate_length(:description, max: 4000)
    |> unique_constraint([:company_id, :code])
  end
end
