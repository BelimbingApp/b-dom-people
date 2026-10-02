defmodule Bilimbi.People.Training.ParticipationFact do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_training_participation_facts" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:session_id, :integer)
    field(:employee_id, :integer)
    field(:revision, :integer)
    field(:status, :string)
    field(:reason, :string)
    field(:import_key, :string)
    field(:actor_user_id, :integer)
    field(:impersonator_id, :integer)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:session_id, :employee_id, :status, :reason, :import_key])
    |> validate_required([
      :tenant_id,
      :company_id,
      :session_id,
      :employee_id,
      :revision,
      :status,
      :reason,
      :import_key,
      :actor_user_id
    ])
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:reason, min: 1, max: 2000)
    |> validate_length(:import_key, min: 1, max: 160)
    |> validate_inclusion(:status, ["confirmed", "absent"])
    |> unique_constraint(:import_key, name: :people_training_participation_facts_import)
  end
end
