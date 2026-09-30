defmodule Bilimbi.People.Payroll.Item do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:classification_id, :integer)
    field(:currency, :string)
    field(:amount, :decimal)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [
        :code,
        :name,
        :classification_id,
        :currency,
        :amount,
        :effective_from,
        :effective_to
      ])
      |> validate_required([
        :code,
        :name,
        :classification_id,
        :currency,
        :amount,
        :effective_from
      ])

    changeset =
      if is_float(Map.get(attrs, :amount, Map.get(attrs, "amount"))),
        do: add_error(changeset, :amount, "must be an exact decimal"),
        else: changeset

    changeset
    |> validate_length(:code, max: 60)
    |> validate_length(:name, max: 120)
    |> validate_change(:effective_to, fn :effective_to, value ->
      if get_field(changeset, :effective_from) &&
           Date.compare(value, get_field(changeset, :effective_from)) == :lt,
         do: [effective_to: "must follow start"],
         else: []
    end)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_number(:amount,
      greater_than_or_equal_to: 0,
      less_than: Decimal.new("100000000000000")
    )
    |> foreign_key_constraint(:classification_id)
  end
end
