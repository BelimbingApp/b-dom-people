defmodule Bilimbi.People.Training.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_tables! do
    for {table, fields} <- [
          {"courses",
           "code varchar(80) NOT NULL, name varchar(160) NOT NULL, description text, active boolean NOT NULL, CONSTRAINT people_training_courses_company_id_code_index UNIQUE(company_id, code), UNIQUE(id, tenant_id, company_id)"},
          {"events",
           "course_id bigint NOT NULL, name varchar(160) NOT NULL, capacity integer NOT NULL CHECK(capacity > 0), UNIQUE(id, tenant_id, company_id), FOREIGN KEY(course_id, tenant_id, company_id) REFERENCES people_training_courses(id, tenant_id, company_id)"},
          {"sessions",
           "event_id bigint NOT NULL, name varchar(160) NOT NULL, capacity integer NOT NULL CHECK(capacity > 0), time_zone varchar(100) NOT NULL, starts_at timestamp(0) NOT NULL, ends_at timestamp(0) NOT NULL CHECK(ends_at > starts_at), FOREIGN KEY(event_id, tenant_id, company_id) REFERENCES people_training_events(id, tenant_id, company_id)"}
        ] do
      SQL.query!(
        Repo,
        "CREATE TEMPORARY TABLE people_training_#{table} (id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL, actor_user_id bigint NOT NULL, impersonator_id bigint, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, #{fields})",
        []
      )
    end
  end
end
