defmodule Bilimbi.People.Training.BudgetPolicy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_budget_policies" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:currency, :string)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:amount, :decimal)
    field(:reason, :string)
    field(:supersedes_id, :integer)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(currency effective_from effective_to amount reason supersedes_id)a)
    |> validate_required(
      ~w(tenant_id company_id actor_user_id currency effective_from effective_to amount reason)a
    )
    |> update_change(:currency, &String.trim/1)
    |> validate_length(:currency, min: 1, max: 4000)
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:reason, min: 1, max: 4000)
    |> validate_number(:amount, greater_than_or_equal_to: 0, less_than: 100_000_000_000_000)
    |> validate_change(:amount, fn field, value ->
      if value.exp < -4, do: [{field, "must have at most four decimal places"}], else: []
    end)
    |> check_constraint(:effective_to, name: :people_training_budget_policies_dates)
    |> unique_constraint(:supersedes_id)
  end
end
