defmodule Bilimbi.People.Attendance.Migrations.CreateRosters do
  use Ecto.Migration

  def up do
    create table(:people_attendance_shift_templates, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 40, null: false)
      add(:name, :string, size: 120, null: false)
      add(:start_minute, :integer, null: false)
      add(:end_minute, :integer, null: false)
      add(:break_minutes, :integer, null: false, default: 0)
      add(:status, :string, size: 16, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_shift_templates, [:company_id, :code],
        name: :people_attendance_shift_templates_company_code_unique
      )
    )

    create(
      index(:people_attendance_shift_templates, [:tenant_id, :company_id, :status],
        name: :people_attendance_shift_templates_status_index
      )
    )

    create(
      constraint(:people_attendance_shift_templates, :people_attendance_shift_templates_status_check,
        check: "status IN ('active', 'retired')"
      )
    )

    create(
      constraint(:people_attendance_shift_templates, :people_attendance_shift_templates_span_check,
        check:
          "start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439 AND " <>
            "start_minute <> end_minute AND break_minutes >= 0"
      )
    )

    create table(:people_attendance_roster_entries, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:on_date, :date, null: false)
      add(:kind, :string, size: 16, null: false)

      add(
        :shift_template_id,
        references(:people_attendance_shift_templates, type: :bigint, on_delete: :restrict)
      )

      add(:published_kind, :string, size: 16)

      add(
        :published_shift_template_id,
        references(:people_attendance_shift_templates,
          type: :bigint,
          on_delete: :restrict,
          name: :people_attendance_roster_entries_published_template_fkey
        )
      )

      add(:published_at, :utc_datetime)
      add(:published_by_user_id, :bigint)
      add(:revision, :integer, null: false, default: 1)
      add(:updated_by_user_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_roster_entries, [:company_id, :employee_id, :on_date],
        name: :people_attendance_roster_entries_company_employee_date_unique
      )
    )

    create(
      index(:people_attendance_roster_entries, [:tenant_id, :company_id, :on_date],
        name: :people_attendance_roster_entries_date_index
      )
    )

    create(
      constraint(:people_attendance_roster_entries, :people_attendance_roster_entries_kind_check,
        check:
          "kind IN ('shift', 'rest', 'none') AND (kind = 'shift') = (shift_template_id IS NOT NULL)"
      )
    )

    create(
      constraint(
        :people_attendance_roster_entries,
        :people_attendance_roster_entries_published_check,
        check:
          "(published_kind IS NULL AND published_shift_template_id IS NULL AND published_at IS NULL) OR " <>
            "(published_kind IN ('shift', 'rest') AND published_at IS NOT NULL AND " <>
            "(published_kind = 'shift') = (published_shift_template_id IS NOT NULL))"
      )
    )

    create table(:people_attendance_clocking_locations, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 40, null: false)
      add(:name, :string, size: 120, null: false)
      add(:latitude, :decimal, precision: 9, scale: 6, null: false)
      add(:longitude, :decimal, precision: 9, scale: 6, null: false)
      add(:radius_meters, :integer, null: false)
      add(:status, :string, size: 16, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_clocking_locations, [:company_id, :code],
        name: :people_attendance_clocking_locations_company_code_unique
      )
    )

    create(
      index(:people_attendance_clocking_locations, [:tenant_id, :company_id, :status],
        name: :people_attendance_clocking_locations_status_index
      )
    )

    create(
      constraint(
        :people_attendance_clocking_locations,
        :people_attendance_clocking_locations_point_check,
        check:
          "latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 AND radius_meters > 0"
      )
    )

    create(
      constraint(
        :people_attendance_clocking_locations,
        :people_attendance_clocking_locations_status_check,
        check: "status IN ('active', 'retired')"
      )
    )

    alter table(:people_attendance_clock_events) do
      add(:latitude, :decimal, precision: 9, scale: 6)
      add(:longitude, :decimal, precision: 9, scale: 6)

      add(
        :clocking_location_id,
        references(:people_attendance_clocking_locations, type: :bigint, on_delete: :restrict)
      )
    end

    create(
      constraint(:people_attendance_clock_events, :people_attendance_clock_events_point_check,
        check: "(latitude IS NULL) = (longitude IS NULL)"
      )
    )

    create table(:people_attendance_adjustment_requests, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:request_key, :string, size: 160, null: false)
      add(:event_type, :string, size: 16, null: false)
      add(:proposed_at, :utc_datetime, null: false)
      add(:on_date, :date, null: false)
      add(:timezone, :string, size: 100, null: false)
      add(:reason, :string, size: 500, null: false)
      add(:status, :string, size: 16, null: false)
      add(:requested_by_user_id, :bigint, null: false)
      add(:decided_by_user_id, :bigint)
      add(:decided_at, :utc_datetime)
      add(:decision_note, :string, size: 500)

      add(
        :applied_clock_event_id,
        references(:people_attendance_clock_events,
          type: :bigint,
          on_delete: :restrict,
          name: :people_attendance_adjustment_requests_applied_event_fkey
        )
      )

      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_attendance_adjustment_requests, [:company_id, :request_key],
        name: :people_attendance_adjustment_requests_company_key_unique
      )
    )

    create(
      index(:people_attendance_adjustment_requests, [:tenant_id, :company_id, :status],
        name: :people_attendance_adjustment_requests_status_index
      )
    )

    create(
      index(:people_attendance_adjustment_requests, [:company_id, :employee_id, :on_date],
        name: :people_attendance_adjustment_requests_employee_date_index
      )
    )

    create(
      constraint(
        :people_attendance_adjustment_requests,
        :people_attendance_adjustment_requests_state_check,
        check:
          "event_type IN ('in', 'out') AND " <>
            "status IN ('pending', 'approved', 'rejected', 'cancelled') AND " <>
            "(status = 'pending') = (decided_at IS NULL) AND " <>
            "(status = 'pending') = (decided_by_user_id IS NULL) AND " <>
            "(status = 'approved') = (applied_clock_event_id IS NOT NULL)"
      )
    )
  end

  def down do
    drop(table(:people_attendance_adjustment_requests))
    drop(constraint(:people_attendance_clock_events, :people_attendance_clock_events_point_check))

    alter table(:people_attendance_clock_events) do
      remove(:clocking_location_id)
      remove(:longitude)
      remove(:latitude)
    end

    drop(table(:people_attendance_clocking_locations))
    drop(table(:people_attendance_roster_entries))
    drop(table(:people_attendance_shift_templates))
  end
end
