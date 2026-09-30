defmodule Bilimbi.People.Payroll.AttendanceAllowanceMapping do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_attendance_rule_pay_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:attendance_rule_code, :string)
    field(:item_id, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [:attendance_rule_code, :item_id, :effective_from, :effective_to])
      |> update_change(:attendance_rule_code, &String.trim/1)
      |> validate_required([:attendance_rule_code, :item_id, :effective_from])

    changeset
    |> validate_change(:effective_to, fn :effective_to, value ->
      if get_field(changeset, :effective_from) &&
           Date.compare(value, get_field(changeset, :effective_from)) == :lt,
         do: [effective_to: "must follow start"],
         else: []
    end)
    |> validate_length(:attendance_rule_code, min: 1, max: 40)
    |> foreign_key_constraint(:item_id)
  end
end
