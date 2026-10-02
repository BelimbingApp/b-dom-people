defmodule Bilimbi.People.Training.EvaluationAnswer do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_evaluation_answers" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:review_id, :integer)
    field(:values, :map)
    field(:reason, :string)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(review_id values reason)a)
    |> validate_required(~w(tenant_id company_id actor_user_id review_id values reason)a)
  end
end
