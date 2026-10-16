defmodule Bilimbi.People.Workforce.Migrations.CreateWorkforceEmployments do
  use Ecto.Migration

  # People's employment record. It points at the Core Person and the person's
  # affiliation with the employer company, and keeps the legacy Core Employee
  # ID as the explicit mapping every People module still keys on. Status and
  # date values are copied verbatim from adopted legacy rows, so the table
  # does not refuse a historical value Core itself never constrained; People
  # writes are validated by the changeset instead.
  def up do
    create table(:people_workforce_employments, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:legacy_employee_id, :bigint, null: false)
      add(:person_id, :bigint, null: false)
      add(:affiliation_id, :bigint, null: false)
      add(:employee_number, :string, size: 255, null: false)
      add(:employment_type, :string, size: 255, null: false)
      add(:status, :string, size: 255, null: false)
      add(:employment_start, :date)
      add(:employment_end, :date)
      add(:metadata, :jsonb)
      add(:legacy_created_at, :naive_datetime)
      add(:claimed_at, :naive_datetime, null: false)
      timestamps(type: :naive_datetime)
    end

    create(unique_index(:people_workforce_employments, [:legacy_employee_id]))
    create(unique_index(:people_workforce_employments, [:affiliation_id]))
    create(index(:people_workforce_employments, [:tenant_id, :company_id]))
    create(index(:people_workforce_employments, [:company_id, :employee_number]))
  end

  def down do
    drop(table(:people_workforce_employments))
  end
end
