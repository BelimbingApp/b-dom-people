defmodule Bilimbi.People.Training.Evidence do
  @moduledoc false
  use Ecto.Schema

  schema "people_training_evidence" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:fact_id, :integer)
    field(:artifact_id, Ecto.UUID)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    timestamps()
  end
end
