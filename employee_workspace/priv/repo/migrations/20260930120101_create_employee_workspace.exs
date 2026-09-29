defmodule Bilimbi.People.EmployeeWorkspace.Migrations.CreateEmployeeWorkspace do
  use Ecto.Migration

  def up do
    create table(:people_employee_work_profiles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :employee_id, :bigint, null: false
      add :work_location, :string, size: 200
      add :work_arrangement, :string, size: 120
      add :notes, :text
      timestamps(type: :naive_datetime)
    end

    create unique_index(:people_employee_work_profiles, [:company_id, :employee_id])
    create index(:people_employee_work_profiles, [:tenant_id, :company_id])

    create table(:people_employee_accesses, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :employee_id, :bigint, null: false
      add :portal_enabled, :boolean, null: false, default: false
      add :reason, :text
      timestamps(type: :naive_datetime)
    end

    create unique_index(:people_employee_accesses, [:company_id, :employee_id])
    create index(:people_employee_accesses, [:tenant_id, :company_id])

    create table(:people_employee_change_requests, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :employee_id, :bigint, null: false
      add :field, :string, size: 80, null: false
      add :proposed_value, :string, size: 500, null: false
      add :reason, :text
      add :status, :string, size: 20, null: false, default: "pending"
      add :requested_by_actor_id, :bigint, null: false
      add :reviewed_by_actor_id, :bigint
      add :reviewed_at, :naive_datetime
      timestamps(type: :naive_datetime)
    end

    create index(:people_employee_change_requests, [:tenant_id, :company_id, :employee_id])

    create constraint(:people_employee_change_requests, :people_employee_change_requests_status_check,
             check: "status IN ('pending', 'approved', 'rejected')")

    create table(:people_employee_saved_views, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :actor_id, :bigint, null: false
      add :name, :string, size: 120, null: false
      add :search, :string, size: 200
      add :status, :string, size: 40
      timestamps(type: :naive_datetime)
    end

    create unique_index(:people_employee_saved_views, [:company_id, :actor_id, :name])
    create index(:people_employee_saved_views, [:tenant_id, :company_id, :actor_id])
  end

  def down do
    drop table(:people_employee_saved_views)
    drop table(:people_employee_change_requests)
    drop table(:people_employee_accesses)
    drop table(:people_employee_work_profiles)
  end
end
