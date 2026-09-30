defmodule Bilimbi.People.Skills.ActionType do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skill_action_types" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:requires_provider, :boolean, default: false)
    field(:active, :boolean)
    timestamps(type: :naive_datetime)
  end

  def create_changeset(type, attrs) do
    type
    |> cast(attrs, [:code, :name, :requires_provider])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :name, :requires_provider, :active])
    |> Bilimbi.People.Skills.Code.validate(:code)
    |> validate_length(:name, max: 160)
    |> unique_constraint([:company_id, :code],
      name: :people_skill_action_types_company_code_unique
    )
  end

  def changeset(type, attrs) do
    type
    |> cast(attrs, [:name, :requires_provider])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :requires_provider])
    |> validate_length(:name, max: 160)
  end
end
