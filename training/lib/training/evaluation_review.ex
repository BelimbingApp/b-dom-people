defmodule Bilimbi.People.Training.EvaluationReview do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_evaluation_reviews" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:policy_id, :integer)
    field(:fact_id, :integer)
    field(:kind, :string)
    field(:checkpoint_days, :integer)
    field(:due_on, :date)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(policy_id fact_id kind checkpoint_days due_on)a)
    |> validate_required(
      ~w(tenant_id company_id actor_user_id policy_id fact_id kind checkpoint_days due_on)a
    )
  end
end
