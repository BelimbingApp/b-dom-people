defmodule Bilimbi.People.Training.Session do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_sessions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:event_id, :integer)
    field(:name, :string)
    field(:capacity, :integer)
    field(:time_zone, :string)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:event_id, :name, :capacity, :time_zone, :starts_at, :ends_at])
    |> validate_required([
      :tenant_id,
      :company_id,
      :actor_user_id,
      :event_id,
      :name,
      :capacity,
      :time_zone,
      :starts_at,
      :ends_at
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_number(:capacity, greater_than: 0, less_than_or_equal_to: 2_147_483_647)
    |> validate_length(:time_zone, max: 100)
    |> check_constraint(:ends_at, name: :people_training_sessions_times)
  end
end
