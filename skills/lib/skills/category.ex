defmodule Bilimbi.People.Skills.Category do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skill_categories" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:description, :string)
    field(:active, :boolean)
    timestamps(type: :naive_datetime)
  end

  def create_changeset(category, attrs) do
    category
    |> cast(attrs, [:code])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:code])
    |> Bilimbi.People.Skills.Code.validate(:code)
    |> changeset(attrs)
    |> unique_constraint([:company_id, :code], name: :people_skill_categories_company_code_unique)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :name, :active])
    |> validate_length(:name, max: 160)
    |> validate_length(:description, max: 2000)
  end
end
