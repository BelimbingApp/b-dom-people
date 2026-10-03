defmodule Bilimbi.People.Payroll.Migrations.CreateAttendanceRulePayItems do
  use Ecto.Migration

  def up do
    create table(:people_payroll_allowance_item_mappings) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:created_by_actor_id, :bigint, null: false)
      add(:attendance_rule_code, :string, size: 40, null: false)
      add(:item_id, references(:people_payroll_items, on_delete: :restrict), null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      timestamps(type: :naive_datetime)
    end

    create(
      index(:people_payroll_allowance_item_mappings, [:tenant_id, :company_id],
        name: :people_payroll_allowance_item_mappings_company_index
      )
    )

    create(
      constraint(
        :people_payroll_allowance_item_mappings,
        :people_payroll_allowance_item_mappings_dates,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    execute(
      "CREATE TRIGGER people_payroll_allowance_item_mappings_immutable BEFORE UPDATE OR DELETE ON people_payroll_allowance_item_mappings FOR EACH ROW EXECUTE FUNCTION people_payroll_immutable()"
    )
  end

  def down do
    drop(table(:people_payroll_allowance_item_mappings))
  end
end
