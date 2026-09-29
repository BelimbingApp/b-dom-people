defmodule Bilimbi.People.ReferenceData.Entry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_reference_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:kind, :string)
    field(:code, :string)
    field(:label, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def changeset(entry, attributes) do
    entry
    |> cast(attributes, [:kind, :code, :label, :active])
    |> update_change(:kind, &String.trim/1)
    |> update_change(:code, &String.trim/1)
    |> update_change(:label, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :kind, :code, :label])
    |> validate_length(:kind, min: 1, max: 80)
    |> validate_length(:code, min: 1, max: 100)
    |> validate_length(:label, min: 1, max: 200)
    |> unique_constraint([:company_id, :kind, :code],
      name: :people_reference_entries_company_kind_code_unique
    )
  end
end
