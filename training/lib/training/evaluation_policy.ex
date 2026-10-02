defmodule Bilimbi.People.Training.EvaluationPolicy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_evaluation_policies" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    field(:version, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:criteria, :map)
    field(:effectiveness_criteria, :map)
    field(:evaluation_days, :integer)
    field(:checkpoints, :map)
    field(:reminder_days, :integer)
    field(:reason, :string)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(
      attrs,
      ~w(version effective_from effective_to criteria effectiveness_criteria evaluation_days checkpoints reminder_days reason)a
    )
    |> validate_required(
      ~w(tenant_id company_id actor_user_id version effective_from effective_to criteria effectiveness_criteria evaluation_days checkpoints reminder_days reason)a
    )
  end
end
