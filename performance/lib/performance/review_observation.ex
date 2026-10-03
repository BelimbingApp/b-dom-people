defmodule Bilimbi.People.Performance.ReviewObservation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_review_evidence" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:review_id, :integer)
    field(:observation_id, :integer)
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:tenant_id, :company_id, :actor_user_id, :review_id, :observation_id])
  end
end
