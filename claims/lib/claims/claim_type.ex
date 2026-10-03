defmodule Bilimbi.People.Claims.ClaimType do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @receipt_requirements ~w(always above_threshold never)
  @eligibilities ~w(all_employees assigned_only)

  schema "people_claim_catalog_types" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:category_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:receipt_requirement, :string)
    field(:eligibility, :string, default: "all_employees")
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def receipt_requirements, do: @receipt_requirements
  def eligibilities, do: @eligibilities

  def changeset(claim_type, attrs) do
    claim_type
    |> cast(attrs, [:code, :name, :receipt_requirement, :eligibility])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:category_id, :code, :name, :receipt_requirement])
    |> validate_length(:code, max: 60)
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:receipt_requirement, @receipt_requirements)
    |> validate_inclusion(:eligibility, @eligibilities)
    |> unique_constraint([:company_id, :code],
      name: :people_claim_catalog_types_company_code_unique
    )
  end
end
