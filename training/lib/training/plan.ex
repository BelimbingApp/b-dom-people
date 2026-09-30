defmodule Bilimbi.People.Training.Plan do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_plans" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:plan_key, :string)
    field(:version, :integer)
    field(:manager_employee_id, :integer)
    field(:period_start, :date)
    field(:period_end, :date)
    field(:objectives, :string)
    field(:status, :string)
    field(:prior_plan_id, :integer)
    field(:reason, :string)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(
      attrs,
      ~w(plan_key version manager_employee_id period_start period_end objectives status prior_plan_id reason)a
    )
    |> validate_required(
      ~w(tenant_id company_id actor_user_id plan_key version manager_employee_id period_start period_end objectives status reason)a
    )
    |> update_change(:plan_key, &String.trim/1)
    |> validate_length(:plan_key, min: 1, max: 4000)
    |> update_change(:objectives, &String.trim/1)
    |> validate_length(:objectives, min: 1, max: 4000)
    |> update_change(:status, &String.trim/1)
    |> validate_length(:status, min: 1, max: 4000)
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:reason, min: 1, max: 4000)
    |> check_constraint(:period_end, name: :people_training_plans_dates)
  end
end
