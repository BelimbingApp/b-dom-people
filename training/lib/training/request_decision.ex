defmodule Bilimbi.People.Training.RequestDecision do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_request_decisions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:request_id, :integer)
    field(:action, :string)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:reason, :string)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(request_id action from_status to_status reason)a)
    |> validate_required(
      ~w(tenant_id company_id actor_user_id action from_status to_status reason)a
    )
    |> update_change(:action, &String.trim/1)
    |> validate_length(:action, min: 1, max: 4000)
    |> update_change(:from_status, &String.trim/1)
    |> validate_length(:from_status, min: 1, max: 4000)
    |> update_change(:to_status, &String.trim/1)
    |> validate_length(:to_status, min: 1, max: 4000)
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:reason, min: 1, max: 4000)
  end
end
