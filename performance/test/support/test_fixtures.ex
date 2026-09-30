defmodule Bilimbi.People.Performance.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_descriptions (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        code text NOT NULL,
        version integer NOT NULL,
        position_id bigint NOT NULL,
        position_version integer NOT NULL,
        effective_from date NOT NULL,
        effective_to date,
        purpose text NOT NULL,
        responsibilities text NOT NULL,
        duties text NOT NULL,
        authority text NOT NULL,
        qualifications text NOT NULL,
        competency_links jsonb NOT NULL,
        status text NOT NULL,
        published_at timestamp(0),
        published_by_user_id bigint,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_descriptions_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_descriptions_identity_unique UNIQUE (company_id, code, version),
        CONSTRAINT people_performance_descriptions_version CHECK (version > 0 AND position_version > 0),
        CONSTRAINT people_performance_descriptions_dates CHECK (effective_to IS NULL OR effective_to >= effective_from),
        CONSTRAINT people_performance_descriptions_content CHECK (length(btrim(code)) > 0 AND length(btrim(purpose)) > 0 AND length(btrim(responsibilities)) > 0 AND length(btrim(duties)) > 0 AND length(btrim(authority)) > 0 AND length(btrim(qualifications)) > 0 AND jsonb_typeof(competency_links->'profiles') = 'array' AND jsonb_array_length(competency_links->'profiles') > 0),
        CONSTRAINT people_performance_descriptions_workflow CHECK ((status = 'draft' AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_descriptions_scope_idx ON people_performance_descriptions(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_kpi_definitions (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        code text NOT NULL,
        version integer NOT NULL,
        name text NOT NULL,
        purpose text NOT NULL,
        unit text NOT NULL,
        measure text NOT NULL,
        source_reference text NOT NULL,
        calculation_version text NOT NULL,
        direction text NOT NULL,
        rubric text,
        precision integer NOT NULL,
        interpretation text NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_kpi_definitions_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_kpi_definitions_identity_unique UNIQUE (company_id, code, version),
        CONSTRAINT people_performance_kpi_definitions_version CHECK (version > 0 AND precision BETWEEN 0 AND 8),
        CONSTRAINT people_performance_kpi_definitions_content CHECK (length(btrim(code)) > 0 AND length(btrim(name)) > 0 AND length(btrim(purpose)) > 0 AND length(btrim(unit)) > 0 AND length(btrim(measure)) > 0 AND length(btrim(source_reference)) > 0 AND length(btrim(calculation_version)) > 0 AND length(btrim(interpretation)) > 0),
        CONSTRAINT people_performance_kpi_definitions_direction CHECK (direction IN ('higher', 'lower', 'band', 'rubric') AND (direction <> 'rubric' OR COALESCE(length(btrim(rubric)), 0) > 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_kpi_definitions_scope_idx ON people_performance_kpi_definitions(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_kpi_targets (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        definition_id bigint NOT NULL,
        definition_version integer NOT NULL,
        employee_id bigint NOT NULL,
        target text NOT NULL,
        period_start date NOT NULL,
        period_end date NOT NULL,
        effective_from date NOT NULL,
        version integer NOT NULL,
        supersedes_id bigint,
        change_reason text,
        confidential boolean NOT NULL,
        status text NOT NULL,
        review_note text,
        reviewed_by_user_id bigint,
        published_by_user_id bigint,
        published_at timestamp(0),
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_kpi_targets_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_kpi_targets_supersedes_unique UNIQUE (supersedes_id),
        CONSTRAINT people_performance_kpi_targets_definition_id_scope_fk FOREIGN KEY (definition_id,tenant_id,company_id) REFERENCES people_performance_kpi_definitions(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_kpi_targets_supersedes_id_scope_fk FOREIGN KEY (supersedes_id,tenant_id,company_id) REFERENCES people_performance_kpi_targets(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_kpi_targets_version CHECK (version > 0 AND definition_version > 0),
        CONSTRAINT people_performance_kpi_targets_dates CHECK (period_end >= period_start AND effective_from BETWEEN period_start AND period_end),
        CONSTRAINT people_performance_kpi_targets_content CHECK (length(btrim(target)) > 0),
        CONSTRAINT people_performance_kpi_targets_workflow CHECK ((status = 'proposed' AND review_note IS NULL AND reviewed_by_user_id IS NULL AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'reviewed' AND COALESCE(length(btrim(review_note)), 0) > 0 AND reviewed_by_user_id IS NOT NULL AND reviewed_by_user_id <> actor_user_id AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND NOT confidential AND COALESCE(length(btrim(review_note)), 0) > 0 AND reviewed_by_user_id IS NOT NULL AND reviewed_by_user_id <> actor_user_id AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL AND published_by_user_id <> actor_user_id)),
        CONSTRAINT people_performance_kpi_targets_correction CHECK ((supersedes_id IS NULL AND version = 1 AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND version > 1 AND COALESCE(length(btrim(change_reason)), 0) > 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_kpi_targets_scope_idx ON people_performance_kpi_targets(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_observations (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        employee_id bigint NOT NULL,
        window_start date NOT NULL,
        window_end date NOT NULL,
        evidence text NOT NULL,
        source_reference text NOT NULL,
        source_version text NOT NULL,
        supersedes_id bigint,
        change_reason text,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_observations_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_observations_supersedes_unique UNIQUE (supersedes_id),
        CONSTRAINT people_performance_observations_supersedes_id_scope_fk FOREIGN KEY (supersedes_id,tenant_id,company_id) REFERENCES people_performance_observations(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_observations_dates CHECK (window_end >= window_start),
        CONSTRAINT people_performance_observations_content CHECK (length(btrim(evidence)) > 0 AND length(btrim(source_reference)) > 0 AND length(btrim(source_version)) > 0),
        CONSTRAINT people_performance_observations_correction CHECK ((supersedes_id IS NULL AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND COALESCE(length(btrim(change_reason)), 0) > 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_observations_scope_idx ON people_performance_observations(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_reviews (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        employee_id bigint NOT NULL,
        description_id bigint NOT NULL,
        period_start date NOT NULL,
        period_end date NOT NULL,
        cutoff_at timestamp(0) NOT NULL,
        outcome text NOT NULL,
        rationale text NOT NULL,
        version integer NOT NULL,
        supersedes_id bigint,
        change_reason text,
        status text NOT NULL,
        released_at timestamp(0),
        released_by_user_id bigint,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_reviews_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_reviews_supersedes_unique UNIQUE (supersedes_id),
        CONSTRAINT people_performance_reviews_supersedes_id_scope_fk FOREIGN KEY (supersedes_id,tenant_id,company_id) REFERENCES people_performance_reviews(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_reviews_description_id_scope_fk FOREIGN KEY (description_id,tenant_id,company_id) REFERENCES people_performance_descriptions(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_reviews_dates CHECK (period_end >= period_start AND cutoff_at::date >= period_end),
        CONSTRAINT people_performance_reviews_content CHECK (length(btrim(outcome)) > 0 AND length(btrim(rationale)) > 0),
        CONSTRAINT people_performance_reviews_workflow CHECK ((status = 'draft' AND released_at IS NULL AND released_by_user_id IS NULL) OR (status = 'released' AND released_at IS NOT NULL AND released_by_user_id IS NOT NULL AND released_by_user_id <> actor_user_id)),
        CONSTRAINT people_performance_reviews_correction CHECK ((supersedes_id IS NULL AND version = 1 AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND version > 1 AND COALESCE(length(btrim(change_reason)), 0) > 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_reviews_scope_idx ON people_performance_reviews(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_review_observations (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        review_id bigint NOT NULL,
        observation_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_review_observations_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_review_observations_identity_unique UNIQUE (review_id, observation_id),
        CONSTRAINT people_performance_review_observations_review_id_scope_fk FOREIGN KEY (review_id,tenant_id,company_id) REFERENCES people_performance_reviews(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_review_observations_observation_id_scope_fk FOREIGN KEY (observation_id,tenant_id,company_id) REFERENCES people_performance_observations(id,tenant_id,company_id) ON DELETE RESTRICT
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_review_observations_scope_idx ON people_performance_review_observations(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_review_targets (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        review_id bigint NOT NULL,
        target_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_review_targets_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_review_targets_identity_unique UNIQUE (review_id, target_id),
        CONSTRAINT people_performance_review_targets_review_id_scope_fk FOREIGN KEY (review_id,tenant_id,company_id) REFERENCES people_performance_reviews(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_review_targets_target_id_scope_fk FOREIGN KEY (target_id,tenant_id,company_id) REFERENCES people_performance_kpi_targets(id,tenant_id,company_id) ON DELETE RESTRICT
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_review_targets_scope_idx ON people_performance_review_targets(tenant_id,company_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_performance_responses (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        actor_user_id bigint NOT NULL,
        review_id bigint NOT NULL,
        employee_id bigint NOT NULL,
        response text NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_performance_responses_scope_unique UNIQUE (id,tenant_id,company_id),
        CONSTRAINT people_performance_responses_identity_unique UNIQUE (review_id, actor_user_id),
        CONSTRAINT people_performance_responses_review_id_scope_fk FOREIGN KEY (review_id,tenant_id,company_id) REFERENCES people_performance_reviews(id,tenant_id,company_id) ON DELETE RESTRICT,
        CONSTRAINT people_performance_responses_content CHECK (length(btrim(response)) > 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX people_performance_responses_scope_idx ON people_performance_responses(tenant_id,company_id)",
      []
    )

    sql =
      Bilimbi.People.Performance.Migrations.CreatePerformance.guard_sql()
      |> String.replace("people_performance_guard", "pg_temp.people_performance_guard")

    # The owner's production trigger code runs against isolated temporary tables.
    [function | triggers] = String.split(sql, "CREATE TRIGGER")
    SQL.query!(Repo, function, [])
    for trigger <- triggers, do: SQL.query!(Repo, "CREATE TRIGGER" <> trigger, [])
  end
end
