defmodule Bilimbi.People.Leave.Migrations.AddRequests do
  use Ecto.Migration

  def up do
    alter table(:people_leave_catalog_types) do
      add(:balance_required, :boolean, null: false, default: true)
    end

    alter table(:people_leave_policies) do
      add(:carry_forward_cap, :decimal, precision: 8, scale: 2)
    end

    create(
      constraint(:people_leave_policies, :people_leave_policies_carry_forward_cap_non_negative,
        check: "carry_forward_cap IS NULL OR carry_forward_cap >= 0"
      )
    )

    create table(:people_leave_applications, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)

      add(
        :leave_type_id,
        references(:people_leave_catalog_types, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:leave_year, :integer, null: false)
      add(:starts_on, :date, null: false)
      add(:ends_on, :date, null: false)
      add(:day_part, :string, size: 8, null: false)
      add(:quantity, :decimal, precision: 10, scale: 2, null: false)
      add(:unit, :string, size: 8, null: false)
      add(:status, :string, size: 16, null: false)
      add(:reason, :string, size: 500)
      add(:request_key, :string, size: 160, null: false)
      add(:requested_by_user_id, :bigint, null: false)
      add(:decided_by_user_id, :bigint)
      add(:decided_at, :utc_datetime_usec)
      add(:decision_note, :string, size: 500)
      add(:cancelled_by_user_id, :bigint)
      add(:cancelled_at, :utc_datetime_usec)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_leave_applications, [:company_id, :employee_id, :request_key],
        name: :people_leave_applications_employee_key_unique
      )
    )

    create(index(:people_leave_applications, [:tenant_id, :company_id, :status]))

    create(
      index(:people_leave_applications, [:tenant_id, :company_id, :employee_id, :leave_year],
        name: :people_leave_applications_employee_year_index
      )
    )

    create(
      constraint(:people_leave_applications, :people_leave_applications_date_range,
        check: "ends_on >= starts_on"
      )
    )

    create(
      constraint(:people_leave_applications, :people_leave_applications_quantity_positive,
        check: "quantity > 0"
      )
    )

    create(
      constraint(:people_leave_applications, :people_leave_applications_status,
        check: "status IN ('pending', 'approved', 'rejected', 'cancelled')"
      )
    )

    create(
      constraint(:people_leave_applications, :people_leave_applications_day_part,
        check: "day_part IN ('full', 'am', 'pm', 'hours')"
      )
    )

    # One row per counted date. A live request holds its half-day slots, so two
    # live requests can never cover the same half of one employee's date.
    create table(:people_leave_application_dates, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)

      add(
        :request_id,
        references(:people_leave_applications, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:on_date, :date, null: false)
      add(:am, :boolean, null: false)
      add(:pm, :boolean, null: false)
      add(:quantity, :decimal, precision: 10, scale: 2, null: false)
      add(:active, :boolean, null: false)
    end

    create(
      unique_index(:people_leave_application_dates, [:request_id, :on_date],
        name: :people_leave_application_dates_request_date_unique
      )
    )

    create(
      unique_index(:people_leave_application_dates, [:company_id, :employee_id, :on_date],
        name: :people_leave_application_dates_am_unique,
        where: "active AND am"
      )
    )

    create(
      unique_index(:people_leave_application_dates, [:company_id, :employee_id, :on_date],
        name: :people_leave_application_dates_pm_unique,
        where: "active AND pm"
      )
    )

    create(
      constraint(:people_leave_application_dates, :people_leave_application_dates_slot,
        check: "am OR pm"
      )
    )

    create table(:people_leave_request_events, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(
        :request_id,
        references(:people_leave_applications, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:from_status, :string, size: 16)
      add(:to_status, :string, size: 16, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:note, :string, size: 500)
      add(:occurred_at, :utc_datetime_usec, null: false)
    end

    create(index(:people_leave_request_events, [:request_id]))

    # Request history is append-only, like the ledger.
    execute("""
    CREATE FUNCTION people_leave_request_events_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'people_leave_request_events is append-only';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_leave_request_events_append_only
    BEFORE UPDATE OR DELETE ON people_leave_request_events
    FOR EACH ROW EXECUTE FUNCTION people_leave_request_events_append_only()
    """)
  end

  def down do
    drop(table(:people_leave_request_events))
    execute("DROP FUNCTION people_leave_request_events_append_only()")
    drop(table(:people_leave_application_dates))
    drop(table(:people_leave_applications))

    drop(
      constraint(:people_leave_policies, :people_leave_policies_carry_forward_cap_non_negative)
    )

    alter table(:people_leave_policies) do
      remove(:carry_forward_cap)
    end

    alter table(:people_leave_catalog_types) do
      remove(:balance_required)
    end
  end
end
