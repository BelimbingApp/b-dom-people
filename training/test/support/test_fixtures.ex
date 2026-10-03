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
          {"session_runs",
           "event_id bigint NOT NULL, name varchar(160) NOT NULL, capacity integer NOT NULL CHECK(capacity > 0), time_zone varchar(100) NOT NULL, starts_at timestamp(0) NOT NULL, ends_at timestamp(0) NOT NULL CHECK(ends_at > starts_at), FOREIGN KEY(event_id, tenant_id, company_id) REFERENCES people_training_events(id, tenant_id, company_id)"}
        ] do
      SQL.query!(
        Repo,
        "CREATE TEMPORARY TABLE people_training_#{table} (id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL, actor_user_id bigint NOT NULL, impersonator_id bigint, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, #{fields})",
        []
      )
    end
  end

  def create_participation_tables! do
    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX ON people_training_session_runs(id, tenant_id, company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_training_attendance_facts (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        session_id bigint NOT NULL, employee_id bigint NOT NULL, revision integer NOT NULL,
        status varchar(20) NOT NULL, reason text NOT NULL, import_key varchar(160) NOT NULL,
        actor_user_id bigint NOT NULL, impersonator_id bigint,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_training_attendance_facts_import UNIQUE(tenant_id, company_id, import_key),
        UNIQUE(session_id, employee_id, revision), UNIQUE(id, tenant_id, company_id),
        FOREIGN KEY(session_id, tenant_id, company_id) REFERENCES people_training_session_runs(id, tenant_id, company_id))
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_training_evidence (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        fact_id bigint NOT NULL, artifact_id uuid NOT NULL UNIQUE,
        actor_user_id bigint NOT NULL, impersonator_id bigint,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        FOREIGN KEY(fact_id, tenant_id, company_id) REFERENCES people_training_attendance_facts(id, tenant_id, company_id))
      """,
      []
    )
  end

  def migrate_evaluation_tables! do
    migrate_governance_tables!()

    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20261002060501_create_training_evaluation.exs",
        __DIR__
      )
    )

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_002_060_501,
      Bilimbi.People.Training.Migrations.CreateEvaluation,
      :forward,
      :change,
      :up,
      log: false
    )
  end

  def migrate_governance_tables! do
    for {file, module, version} <- [
          {"20261001060101_create_people_training_catalog.exs",
           Bilimbi.People.Training.Migrations.CreateCatalog, 20_261_001_060_101},
          {"20261001060201_create_training_participation.exs",
           Bilimbi.People.Training.Migrations.CreateParticipation, 20_261_001_060_201},
          {"20261001060401_create_people_learning_governance.exs",
           Bilimbi.People.Training.Migrations.CreateLearningGovernance, 20_261_001_060_401}
        ] do
      Code.require_file(Path.expand("../../priv/repo/migrations/" <> file, __DIR__))

      Ecto.Migration.Runner.run(Repo, Repo.config(), version, module, :forward, :change, :up,
        log: false
      )
    end
  end
end
