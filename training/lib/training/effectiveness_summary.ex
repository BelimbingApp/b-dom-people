defmodule Bilimbi.People.Training.EffectivenessSummary do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_effectiveness_summaries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:period_start, :date)
    field(:period_end, :date)
    field(:minimum_cohort, :integer)
    field(:status, :string)
    field(:groups, :map)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, ~w(period_start period_end minimum_cohort status groups)a)
    |> validate_required(
      ~w(tenant_id company_id actor_user_id period_start period_end minimum_cohort status groups)a
    )
  end
end
