defmodule Bilimbi.People.Workforce.Migrations.CreateWorkforceEmploymentExceptions do
  use Ecto.Migration

  # Legacy Core Employee rows People could not claim, and why, so an operator
  # sees them instead of finding them silently Core-only. A claim run rewrites
  # a company's rows; claiming an employee removes theirs.
  def up do
    create table(:people_workforce_employment_exceptions, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:legacy_employee_id, :bigint, null: false)
      add(:reason, :string, size: 64, null: false)
      add(:detected_at, :naive_datetime, null: false)
      timestamps(type: :naive_datetime)
    end

    create(unique_index(:people_workforce_employment_exceptions, [:legacy_employee_id]))

    create(
      index(:people_workforce_employment_exceptions, [:tenant_id, :company_id],
        name: :people_workforce_employment_exceptions_company_index
      )
    )
  end

  def down do
    drop(table(:people_workforce_employment_exceptions))
  end
end
