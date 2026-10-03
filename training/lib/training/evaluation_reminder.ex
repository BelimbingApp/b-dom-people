defmodule Bilimbi.People.Training.EvaluationReminder do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_review_reminders" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:review_id, :integer)
    field(:recipient_employee_id, :integer)
    field(:available_on, :date)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(review_id recipient_employee_id available_on)a)
    |> validate_required(
      ~w(tenant_id company_id actor_user_id review_id recipient_employee_id available_on)a
    )
  end
end
