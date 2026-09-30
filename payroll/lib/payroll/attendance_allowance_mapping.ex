defmodule Bilimbi.People.Payroll.AttendanceAllowanceMapping do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_attendance_rule_pay_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:attendance_rule_code, :string)
    field(:pay_item_code, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:attendance_rule_code, :pay_item_code])
    |> update_change(:attendance_rule_code, &String.trim/1)
    |> update_change(:pay_item_code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :attendance_rule_code, :pay_item_code])
    |> validate_length(:attendance_rule_code, min: 1, max: 40)
    |> validate_length(:pay_item_code, min: 1, max: 40)
    |> validate_format(:pay_item_code, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/)
    |> unique_constraint([:company_id, :attendance_rule_code],
      name: :people_payroll_attendance_rule_pay_items_company_rule_unique
    )
  end
end
