defmodule Bilimbi.People.Leave.Migrations.AddCarryForwardSkips do
  use Ecto.Migration

  # The employees and types the latest carry-forward run of a leave year left
  # open, with the reason; each run replaces its year's rows.
  def change do
    create table(:people_leave_carry_forward_skips, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:from_year, :integer, null: false)
      add(:employee_id, :bigint, null: false)
      add(:employee_label, :string, size: 300, null: false)

      add(:leave_type_id, references(:people_leave_types, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:reason, :string, size: 24, null: false)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create(
      unique_index(
        :people_leave_carry_forward_skips,
        [:company_id, :from_year, :employee_id, :leave_type_id],
        name: :people_leave_carry_forward_skips_unique
      )
    )

    create(
      constraint(:people_leave_carry_forward_skips, :people_leave_carry_forward_skips_reason,
        check: "reason IN ('pending', 'previous_year_open')"
      )
    )
  end
end
