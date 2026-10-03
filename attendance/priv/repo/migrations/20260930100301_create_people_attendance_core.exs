defmodule Bilimbi.People.Attendance.Migrations.CreateCore do
  use Ecto.Migration

  def up do
    create table(:people_attendance_daily_summaries, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:on_date, :date, null: false)
      add(:status, :string, size: 32, null: false)
      add(:first_in_at, :utc_datetime)
      add(:last_out_at, :utc_datetime)
      add(:worked_minutes, :integer, null: false, default: 0)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_daily_summaries, [:company_id, :employee_id, :on_date],
        name: :people_attendance_daily_summaries_company_employee_date_unique
      )
    )

    create(
      index(:people_attendance_daily_summaries, [:tenant_id, :company_id, :on_date],
        name: :people_attendance_daily_summaries_scope_date_index
      )
    )

    create table(:people_attendance_clock_facts, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)

      add(
        :day_id,
        references(:people_attendance_daily_summaries, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:event_key, :string, size: 160, null: false)
      add(:event_type, :string, size: 16, null: false)
      add(:source, :string, size: 32, null: false)
      add(:occurred_at, :utc_datetime, null: false)
      add(:timezone, :string, size: 100, null: false)
      add(:actor_user_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_clock_facts, [:company_id, :source, :event_key],
        name: :people_attendance_events_source_key_unique
      )
    )

    create(
      index(:people_attendance_clock_facts, [:tenant_id, :company_id, :employee_id, :occurred_at],
        name: :people_attendance_clock_facts_employee_time_index
      )
    )
  end

  def down do
    drop(table(:people_attendance_clock_facts))
    drop(table(:people_attendance_daily_summaries))
  end
end
