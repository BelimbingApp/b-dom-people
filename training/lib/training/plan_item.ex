defmodule Bilimbi.People.Training.PlanItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_plan_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:plan_id, :integer)
    field(:request_id, :integer)
    field(:need, :string)
    field(:expected_result, :string)
    field(:target_cohort, :string)
    field(:responsible_owner, :string)
    field(:intended_timing, :string)
    field(:evaluation_approach, :string)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(
      attrs,
      ~w(plan_id request_id need expected_result target_cohort responsible_owner intended_timing evaluation_approach)a
    )
    |> validate_required(
      ~w(tenant_id company_id actor_user_id plan_id need expected_result target_cohort responsible_owner intended_timing evaluation_approach)a
    )
    |> update_change(:need, &String.trim/1)
    |> validate_length(:need, min: 1, max: 4000)
    |> update_change(:expected_result, &String.trim/1)
    |> validate_length(:expected_result, min: 1, max: 4000)
    |> update_change(:target_cohort, &String.trim/1)
    |> validate_length(:target_cohort, min: 1, max: 4000)
    |> update_change(:responsible_owner, &String.trim/1)
    |> validate_length(:responsible_owner, min: 1, max: 4000)
    |> update_change(:intended_timing, &String.trim/1)
    |> validate_length(:intended_timing, min: 1, max: 4000)
    |> update_change(:evaluation_approach, &String.trim/1)
    |> validate_length(:evaluation_approach, min: 1, max: 4000)
  end
end
