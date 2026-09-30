defmodule Bilimbi.People.Skills.Skill do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skills" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:category_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:definition, :string)
    field(:evidence_guide, :string)
    field(:critical, :boolean, default: false)
    field(:reassessment_months, :integer)
    field(:active, :boolean)
    timestamps(type: :naive_datetime)
  end

  def create_changeset(skill, attrs) do
    skill
    |> cast(attrs, [:code])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:code])
    |> Bilimbi.People.Skills.Code.validate(:code)
    |> changeset(attrs)
    |> unique_constraint([:company_id, :code], name: :people_skills_company_code_unique)
  end

  @doc "Revises everything but the stable code, company and availability."
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :category_id,
      :name,
      :definition,
      :evidence_guide,
      :critical,
      :reassessment_months
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:definition, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :category_id,
      :code,
      :name,
      :definition,
      :critical,
      :active
    ])
    |> validate_length(:name, max: 160)
    |> validate_length(:definition, max: 2000)
    |> validate_length(:evidence_guide, max: 2000)
    |> validate_number(:reassessment_months,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 120
    )
    |> foreign_key_constraint(:category_id)
  end
end
