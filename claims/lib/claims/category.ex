defmodule Bilimbi.People.Claims.Category do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_claim_catalog_groups" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:code, :name])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:code, :name])
    |> validate_length(:code, max: 60)
    |> validate_length(:name, max: 120)
    |> unique_constraint([:company_id, :code],
      name: :people_claim_catalog_groups_company_code_unique
    )
  end
end
