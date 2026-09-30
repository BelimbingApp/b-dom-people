defmodule Bilimbi.People.Attendance.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_attendance_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_days (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, on_date date NOT NULL, status varchar(32) NOT NULL,
        first_in_at timestamp(0), last_out_at timestamp(0),
        worked_minutes integer NOT NULL DEFAULT 0,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_days_company_employee_date_unique
          UNIQUE (company_id, employee_id, on_date)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_clock_events (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, day_id bigint NOT NULL,
        event_key varchar(160) NOT NULL, event_type varchar(16) NOT NULL,
        source varchar(32) NOT NULL, occurred_at timestamp(0) NOT NULL,
        timezone varchar(100) NOT NULL, actor_user_id bigint,
        latitude numeric(9,6), longitude numeric(9,6), clocking_location_id bigint,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_events_source_key_unique
          UNIQUE (company_id, source, event_key)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_shift_templates (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(40) NOT NULL, name varchar(120) NOT NULL,
        start_minute integer NOT NULL, end_minute integer NOT NULL,
        break_minutes integer NOT NULL DEFAULT 0, status varchar(16) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_shift_templates_company_code_unique UNIQUE (company_id, code),
        CHECK (start_minute BETWEEN 0 AND 1439 AND end_minute BETWEEN 0 AND 1439 AND
          start_minute <> end_minute AND break_minutes >= 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_roster_entries (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, on_date date NOT NULL, kind varchar(16) NOT NULL,
        shift_template_id bigint REFERENCES people_attendance_shift_templates(id),
        published_kind varchar(16),
        published_shift_template_id bigint REFERENCES people_attendance_shift_templates(id),
        published_at timestamp(0), published_by_user_id bigint,
        revision integer NOT NULL DEFAULT 1, updated_by_user_id bigint,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_roster_entries_company_employee_date_unique
          UNIQUE (company_id, employee_id, on_date),
        CHECK (kind IN ('shift', 'rest', 'none') AND (kind = 'shift') = (shift_template_id IS NOT NULL)),
        CHECK ((published_kind IS NULL AND published_shift_template_id IS NULL AND published_at IS NULL) OR
          (published_kind IN ('shift', 'rest') AND published_at IS NOT NULL AND
           (published_kind = 'shift') = (published_shift_template_id IS NOT NULL)))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_clocking_locations (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(40) NOT NULL, name varchar(120) NOT NULL,
        latitude numeric(9,6) NOT NULL, longitude numeric(9,6) NOT NULL,
        radius_meters integer NOT NULL, status varchar(16) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_clocking_locations_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_adjustment_requests (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, request_key varchar(160) NOT NULL,
        event_type varchar(16) NOT NULL, proposed_at timestamp(0) NOT NULL,
        on_date date NOT NULL, timezone varchar(100) NOT NULL, reason varchar(500) NOT NULL,
        status varchar(16) NOT NULL, requested_by_user_id bigint NOT NULL,
        decided_by_user_id bigint, decided_at timestamp(0), decision_note varchar(500),
        applied_clock_event_id bigint REFERENCES people_attendance_clock_events(id),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_adjustment_requests_company_key_unique
          UNIQUE (company_id, request_key),
        CHECK ((status = 'pending') = (decided_at IS NULL) AND
          (status = 'approved') = (applied_clock_event_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_attendance_allowance_rules (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(40) NOT NULL, name varchar(120) NOT NULL, unit varchar(32) NOT NULL,
        value numeric(14,4) NOT NULL, currency varchar(3) NOT NULL,
        effective_from date NOT NULL, effective_until date,
        status varchar(16) NOT NULL DEFAULT 'active',
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_allowance_rules_company_code_from_unique
          UNIQUE (company_id, code, effective_from),
        CHECK (status IN ('active', 'retired')), CHECK (value > 0),
        CHECK (effective_until IS NULL OR effective_until >= effective_from)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
