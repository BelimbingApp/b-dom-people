defmodule Bilimbi.People.Payroll.Contribution do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_contributions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:run_id, :integer)
    field(:employee_id, :integer)
    field(:item_id, :integer)
    field(:source_key, :string)
    field(:evidence, :string)
    field(:on_date, :date)
    field(:units, :decimal)
    field(:direction, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:employee_id, :item_id, :source_key, :evidence, :on_date, :units, :direction])
    |> validate_required([:employee_id, :item_id, :source_key, :evidence, :on_date, :units, :direction])
    |> validate_length(:source_key, min: 1, max: 120)
    |> validate_length(:evidence, min: 1, max: 500)
    |> validate_inclusion(:direction, ["earning", "deduction", "employer"])
    |> validate_number(:units, greater_than: 0, less_than: Decimal.new("100000000000000"))
    |> validate_change(:units, fn :units, value ->
      if is_float(Map.get(attrs, :units, Map.get(attrs, "units"))) or
           not Decimal.equal?(value, Decimal.round(value, 6)),
        do: [units: "must be an exact decimal with at most six fractional digits"],
        else: []
    end)
    |> unique_constraint([:company_id, :source_key])
  end
end
