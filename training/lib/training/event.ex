defmodule Bilimbi.People.Training.Event do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:course_id, :integer)
    field(:name, :string)
    field(:capacity, :integer)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:course_id, :name, :capacity])
    |> validate_required([:tenant_id, :company_id, :actor_user_id, :course_id, :name, :capacity])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_number(:capacity, greater_than: 0, less_than_or_equal_to: 2_147_483_647)
  end
end
