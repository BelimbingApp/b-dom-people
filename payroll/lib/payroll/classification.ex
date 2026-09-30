defmodule Bilimbi.People.Payroll.Classification do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_classifications" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [:code, :name, :effective_from, :effective_to])
      |> validate_required([:code, :name, :effective_from])

    changeset
    |> validate_length(:code, max: 60)
    |> validate_length(:name, max: 120)
    |> validate_change(:effective_to, fn :effective_to, value ->
      if get_field(changeset, :effective_from) &&
           Date.compare(value, get_field(changeset, :effective_from)) == :lt,
         do: [effective_to: "must follow start"],
         else: []
    end)
  end
end
