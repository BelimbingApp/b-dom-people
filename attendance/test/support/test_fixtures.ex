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
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_attendance_events_source_key_unique
          UNIQUE (company_id, source, event_key)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
