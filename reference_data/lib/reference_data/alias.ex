defmodule Bilimbi.People.ReferenceData.Alias do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_reference_aliases" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:entry_id, :integer)
    field(:label, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(alias_record, attributes) do
    alias_record
    |> cast(attributes, [:label])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :entry_id, :label])
    |> validate_length(:label, min: 1, max: 200)
    |> unique_constraint([:company_id, :label],
      name: :people_reference_aliases_company_label_unique
    )
  end
end
