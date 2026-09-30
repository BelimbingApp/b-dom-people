defmodule Bilimbi.People.Training.Migrations.CreateCatalog do
  use Ecto.Migration

  def change do
    create table(:people_training_courses) do
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :code, :string, size: 80, null: false
      add :name, :string, size: 160, null: false
      add :description, :text
      add :active, :boolean, null: false
      add :actor_user_id, :bigint, null: false
      add :impersonator_id, :bigint
      timestamps()
    end

    create unique_index(:people_training_courses, [:company_id, :code])
    create unique_index(:people_training_courses, [:id, :tenant_id, :company_id])

    create table(:people_training_events) do
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :course_id, :bigint, null: false
      add :name, :string, size: 160, null: false
      add :capacity, :integer, null: false
      add :actor_user_id, :bigint, null: false
      add :impersonator_id, :bigint
      timestamps()
    end

    create unique_index(:people_training_events, [:id, :tenant_id, :company_id])

    create constraint(:people_training_events, :people_training_events_capacity,
             check: "capacity > 0"
           )

    execute "ALTER TABLE people_training_events ADD CONSTRAINT people_training_events_course_scope FOREIGN KEY (course_id, tenant_id, company_id) REFERENCES people_training_courses (id, tenant_id, company_id)",
            "ALTER TABLE people_training_events DROP CONSTRAINT people_training_events_course_scope"

    create table(:people_training_sessions) do
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :event_id, :bigint, null: false
      add :name, :string, size: 160, null: false
      add :capacity, :integer, null: false
      add :time_zone, :string, size: 100, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :actor_user_id, :bigint, null: false
      add :impersonator_id, :bigint
      timestamps()
    end

    create index(:people_training_sessions, [:tenant_id, :company_id, :starts_at])

    create constraint(:people_training_sessions, :people_training_sessions_capacity,
             check: "capacity > 0"
           )

    create constraint(:people_training_sessions, :people_training_sessions_times,
             check: "ends_at > starts_at"
           )

    execute "ALTER TABLE people_training_sessions ADD CONSTRAINT people_training_sessions_event_scope FOREIGN KEY (event_id, tenant_id, company_id) REFERENCES people_training_events (id, tenant_id, company_id)",
            "ALTER TABLE people_training_sessions DROP CONSTRAINT people_training_sessions_event_scope"

    execute """
            CREATE FUNCTION people_training_session_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE event_capacity integer;
            BEGIN
              SELECT capacity INTO event_capacity FROM people_training_events
                WHERE id = NEW.event_id AND tenant_id = NEW.tenant_id AND company_id = NEW.company_id
                FOR UPDATE;
              IF event_capacity IS NULL OR NEW.capacity > event_capacity THEN
                RAISE EXCEPTION 'Session capacity exceeds its scoped event' USING ERRCODE = '23514';
              END IF;
              IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.time_zone) THEN
                RAISE EXCEPTION 'Unknown session time zone' USING ERRCODE = '23514';
              END IF;
              RETURN NEW;
            END $$
            """,
            "DROP FUNCTION people_training_session_guard()"

    execute "CREATE TRIGGER people_training_session_guard BEFORE INSERT OR UPDATE ON people_training_sessions FOR EACH ROW EXECUTE FUNCTION people_training_session_guard()",
            "DROP TRIGGER people_training_session_guard ON people_training_sessions"

    execute """
            CREATE FUNCTION people_training_event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF EXISTS (SELECT 1 FROM people_training_sessions WHERE event_id = NEW.id AND capacity > NEW.capacity) THEN
                RAISE EXCEPTION 'Event capacity is below a session capacity' USING ERRCODE = '23514';
              END IF;
              RETURN NEW;
            END $$
            """,
            "DROP FUNCTION people_training_event_guard()"

    execute "CREATE TRIGGER people_training_event_guard BEFORE UPDATE ON people_training_events FOR EACH ROW EXECUTE FUNCTION people_training_event_guard()",
            "DROP TRIGGER people_training_event_guard ON people_training_events"
  end
end
