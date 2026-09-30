defmodule Bilimbi.People.Payroll.Period do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_periods" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:code, :string)
    field(:starts_on, :date)
    field(:ends_on, :date)
    field(:pay_on, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [:code, :starts_on, :ends_on, :pay_on])
      |> validate_required([:code, :starts_on, :ends_on, :pay_on])

    changeset
    |> validate_length(:code, max: 60)
    |> unique_constraint(:code, name: :people_payroll_periods_company_id_code_index)
    |> validate_change(:ends_on, fn :ends_on, value ->
      if get_field(changeset, :starts_on) &&
           Date.compare(value, get_field(changeset, :starts_on)) == :lt,
         do: [ends_on: "must follow start"],
         else: []
    end)
  end
end
