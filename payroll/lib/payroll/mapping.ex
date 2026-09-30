defmodule Bilimbi.People.Payroll.Mapping do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_mappings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:source_kind, :string)
    field(:source_key, :string)
    field(:item_id, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [:source_kind, :source_key, :item_id, :effective_from, :effective_to])
      |> validate_required([:source_kind, :source_key, :item_id, :effective_from])

    changeset
    |> validate_change(:effective_to, fn :effective_to, value ->
      if get_field(changeset, :effective_from) &&
           Date.compare(value, get_field(changeset, :effective_from)) == :lt,
         do: [effective_to: "must follow start"],
         else: []
    end)
    |> validate_length(:source_key, max: 100)
    |> validate_inclusion(:source_kind, ~w(leave claims))
    |> foreign_key_constraint(:item_id)
  end
end
