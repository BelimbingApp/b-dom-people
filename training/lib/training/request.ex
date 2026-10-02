defmodule Bilimbi.People.Training.Request do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:employee_id, :integer)
    field(:course_id, :integer)
    field(:need, :string)
    field(:objective, :string)
    field(:expected_result, :string)
    field(:proposed_on, :date)
    field(:estimated_cost, :decimal)
    field(:currency, :string)
    field(:status, :string)
    field(:budget_policy_id, :integer)
    field(:approved_cost, :decimal)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(
      attrs,
      ~w(employee_id course_id need objective expected_result proposed_on estimated_cost currency status budget_policy_id approved_cost)a
    )
    |> validate_required(
      ~w(tenant_id company_id actor_user_id employee_id need objective expected_result proposed_on estimated_cost currency status)a
    )
    |> update_change(:need, &String.trim/1)
    |> validate_length(:need, min: 1, max: 4000)
    |> update_change(:objective, &String.trim/1)
    |> validate_length(:objective, min: 1, max: 4000)
    |> update_change(:expected_result, &String.trim/1)
    |> validate_length(:expected_result, min: 1, max: 4000)
    |> update_change(:currency, &String.trim/1)
    |> validate_length(:currency, min: 1, max: 4000)
    |> update_change(:status, &String.trim/1)
    |> validate_length(:status, min: 1, max: 4000)
    |> validate_number(:estimated_cost,
      greater_than_or_equal_to: 0,
      less_than: 100_000_000_000_000
    )
    |> validate_number(:approved_cost,
      greater_than_or_equal_to: 0,
      less_than: 100_000_000_000_000
    )
    |> validate_change(:estimated_cost, fn field, value ->
      if value.exp < -4, do: [{field, "must have at most four decimal places"}], else: []
    end)
    |> validate_change(:approved_cost, fn field, value ->
      if value.exp < -4, do: [{field, "must have at most four decimal places"}], else: []
    end)
  end
end
