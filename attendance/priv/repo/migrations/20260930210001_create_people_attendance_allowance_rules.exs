defmodule Bilimbi.People.Attendance.Migrations.CreateAllowanceRules do
  use Ecto.Migration

  def change do
    create table(:people_attendance_allowance_policies, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 40, null: false)
      add(:name, :string, size: 120, null: false)
      add(:unit, :string, size: 32, null: false)
      add(:value, :decimal, precision: 14, scale: 4, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_until, :date)
      add(:status, :string, size: 16, null: false, default: "active")
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_allowance_policies, [:company_id, :code, :effective_from],
        name: :people_attendance_allowance_policies_company_code_from_unique
      )
    )

    create(
      index(:people_attendance_allowance_policies, [:tenant_id, :company_id, :status, :effective_from],
        name: :people_attendance_allowance_policies_company_effective_index
      )
    )

    create(
      constraint(:people_attendance_allowance_policies, :people_attendance_allowance_policies_status_check,
        check: "status IN ('active', 'retired')"
      )
    )

    create(
      constraint(:people_attendance_allowance_policies, :people_attendance_allowance_policies_value_check,
        check: "value > 0"
      )
    )

    create(
      constraint(:people_attendance_allowance_policies, :people_attendance_allowance_policies_period_check,
        check: "effective_until IS NULL OR effective_until >= effective_from"
      )
    )
  end
end
