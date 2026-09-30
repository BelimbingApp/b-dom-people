defmodule Bilimbi.People.Payroll.Migrations.CreateAttendanceRulePayItems do
  use Ecto.Migration

  def change do
    create table(:people_payroll_attendance_rule_pay_items, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:attendance_rule_code, :string, size: 40, null: false)
      add(:pay_item_code, :string, size: 40, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(
        :people_payroll_attendance_rule_pay_items,
        [:company_id, :attendance_rule_code],
        name: :people_payroll_attendance_rule_pay_items_company_rule_unique
      )
    )

    create(
      index(:people_payroll_attendance_rule_pay_items, [:tenant_id, :company_id],
        name: :people_payroll_attendance_rule_pay_items_company_index
      )
    )
  end
end
