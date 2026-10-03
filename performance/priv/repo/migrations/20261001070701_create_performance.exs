defmodule Bilimbi.People.Performance.Migrations.CreatePerformance do
  use Ecto.Migration

  def up do
    create table(:people_performance_descriptions) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:code, :text, null: false)
      add(:version, :integer, null: false)
      add(:position_id, :bigint, null: false)
      add(:position_version, :integer, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date, null: true)
      add(:purpose, :text, null: false)
      add(:responsibilities, :text, null: false)
      add(:duties, :text, null: false)
      add(:authority, :text, null: false)
      add(:qualifications, :text, null: false)
      add(:competency_links, :map, null: false)
      add(:status, :text, null: false)
      add(:published_at, :utc_datetime, null: true)
      add(:published_by_user_id, :bigint, null: true)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_descriptions, [:id, :tenant_id, :company_id],
        name: :people_performance_descriptions_scope_unique
      )
    )

    create(
      index(:people_performance_descriptions, [:tenant_id, :company_id],
        name: :people_performance_descriptions_scope_idx
      )
    )

    create table(:people_performance_kpi_definitions) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:code, :text, null: false)
      add(:version, :integer, null: false)
      add(:name, :text, null: false)
      add(:purpose, :text, null: false)
      add(:unit, :text, null: false)
      add(:measure, :text, null: false)
      add(:source_reference, :text, null: false)
      add(:calculation_version, :text, null: false)
      add(:direction, :text, null: false)
      add(:rubric, :text, null: true)
      add(:precision, :integer, null: false)
      add(:interpretation, :text, null: false)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_kpi_definitions, [:id, :tenant_id, :company_id],
        name: :people_performance_kpi_definitions_scope_unique
      )
    )

    create(
      index(:people_performance_kpi_definitions, [:tenant_id, :company_id],
        name: :people_performance_kpi_definitions_scope_idx
      )
    )

    create table(:people_performance_kpi_targets) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:definition_id, :bigint, null: false)
      add(:definition_version, :integer, null: false)
      add(:employee_id, :bigint, null: false)
      add(:target, :text, null: false)
      add(:period_start, :date, null: false)
      add(:period_end, :date, null: false)
      add(:effective_from, :date, null: false)
      add(:version, :integer, null: false)
      add(:supersedes_id, :bigint, null: true)
      add(:change_reason, :text, null: true)
      add(:confidential, :boolean, null: false)
      add(:status, :text, null: false)
      add(:review_note, :text, null: true)
      add(:reviewed_by_user_id, :bigint, null: true)
      add(:published_by_user_id, :bigint, null: true)
      add(:published_at, :utc_datetime, null: true)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_kpi_targets, [:id, :tenant_id, :company_id],
        name: :people_performance_kpi_targets_scope_unique
      )
    )

    create(
      index(:people_performance_kpi_targets, [:tenant_id, :company_id],
        name: :people_performance_kpi_targets_scope_idx
      )
    )

    create(
      unique_index(:people_performance_kpi_targets, [:supersedes_id],
        name: :people_performance_kpi_targets_supersedes_unique
      )
    )

    create table(:people_performance_evidence) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:window_start, :date, null: false)
      add(:window_end, :date, null: false)
      add(:evidence, :text, null: false)
      add(:source_reference, :text, null: false)
      add(:source_version, :text, null: false)
      add(:supersedes_id, :bigint, null: true)
      add(:change_reason, :text, null: true)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_evidence, [:id, :tenant_id, :company_id],
        name: :people_performance_evidence_scope_unique
      )
    )

    create(
      index(:people_performance_evidence, [:tenant_id, :company_id],
        name: :people_performance_evidence_scope_idx
      )
    )

    create(
      unique_index(:people_performance_evidence, [:supersedes_id],
        name: :people_performance_evidence_supersedes_unique
      )
    )

    create table(:people_performance_appraisals) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:description_id, :bigint, null: false)
      add(:period_start, :date, null: false)
      add(:period_end, :date, null: false)
      add(:cutoff_at, :utc_datetime, null: false)
      add(:outcome, :text, null: false)
      add(:rationale, :text, null: false)
      add(:version, :integer, null: false)
      add(:supersedes_id, :bigint, null: true)
      add(:change_reason, :text, null: true)
      add(:status, :text, null: false)
      add(:released_at, :utc_datetime, null: true)
      add(:released_by_user_id, :bigint, null: true)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_appraisals, [:id, :tenant_id, :company_id],
        name: :people_performance_appraisals_scope_unique
      )
    )

    create(
      index(:people_performance_appraisals, [:tenant_id, :company_id],
        name: :people_performance_appraisals_scope_idx
      )
    )

    create(
      unique_index(:people_performance_appraisals, [:supersedes_id],
        name: :people_performance_appraisals_supersedes_unique
      )
    )

    create table(:people_performance_review_evidence) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:review_id, :bigint, null: false)
      add(:observation_id, :bigint, null: false)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_review_evidence, [:id, :tenant_id, :company_id],
        name: :people_performance_review_evidence_scope_unique
      )
    )

    create(
      index(:people_performance_review_evidence, [:tenant_id, :company_id],
        name: :people_performance_review_evidence_scope_idx
      )
    )

    create table(:people_performance_review_targets) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:review_id, :bigint, null: false)
      add(:target_id, :bigint, null: false)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_review_targets, [:id, :tenant_id, :company_id],
        name: :people_performance_review_targets_scope_unique
      )
    )

    create(
      index(:people_performance_review_targets, [:tenant_id, :company_id],
        name: :people_performance_review_targets_scope_idx
      )
    )

    create table(:people_performance_responses) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:review_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:response, :text, null: false)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_performance_responses, [:id, :tenant_id, :company_id],
        name: :people_performance_responses_scope_unique
      )
    )

    create(
      index(:people_performance_responses, [:tenant_id, :company_id],
        name: :people_performance_responses_scope_idx
      )
    )

    create(
      unique_index(:people_performance_descriptions, [:company_id, :code, :version],
        name: :people_performance_descriptions_identity_unique
      )
    )

    create(
      unique_index(:people_performance_kpi_definitions, [:company_id, :code, :version],
        name: :people_performance_kpi_definitions_identity_unique
      )
    )

    create(
      unique_index(:people_performance_review_evidence, [:review_id, :observation_id],
        name: :people_performance_review_evidence_identity_unique
      )
    )

    create(
      unique_index(:people_performance_review_targets, [:review_id, :target_id],
        name: :people_performance_review_targets_identity_unique
      )
    )

    create(
      unique_index(:people_performance_responses, [:review_id, :actor_user_id],
        name: :people_performance_responses_identity_unique
      )
    )

    execute(
      "ALTER TABLE people_performance_kpi_targets ADD CONSTRAINT people_performance_kpi_targets_definition_id_scope_fk FOREIGN KEY (definition_id, tenant_id, company_id) REFERENCES people_performance_kpi_definitions(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_kpi_targets ADD CONSTRAINT people_performance_kpi_targets_supersedes_id_scope_fk FOREIGN KEY (supersedes_id, tenant_id, company_id) REFERENCES people_performance_kpi_targets(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_evidence ADD CONSTRAINT people_performance_evidence_supersedes_id_scope_fk FOREIGN KEY (supersedes_id, tenant_id, company_id) REFERENCES people_performance_evidence(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_appraisals ADD CONSTRAINT people_performance_appraisals_supersedes_id_scope_fk FOREIGN KEY (supersedes_id, tenant_id, company_id) REFERENCES people_performance_appraisals(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_appraisals ADD CONSTRAINT people_performance_appraisals_description_id_scope_fk FOREIGN KEY (description_id, tenant_id, company_id) REFERENCES people_performance_descriptions(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_review_evidence ADD CONSTRAINT people_performance_review_evidence_review_id_scope_fk FOREIGN KEY (review_id, tenant_id, company_id) REFERENCES people_performance_appraisals(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_review_evidence ADD CONSTRAINT people_performance_review_evidence_observation_id_scope_fk FOREIGN KEY (observation_id, tenant_id, company_id) REFERENCES people_performance_evidence(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_review_targets ADD CONSTRAINT people_performance_review_targets_review_id_scope_fk FOREIGN KEY (review_id, tenant_id, company_id) REFERENCES people_performance_appraisals(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_review_targets ADD CONSTRAINT people_performance_review_targets_target_id_scope_fk FOREIGN KEY (target_id, tenant_id, company_id) REFERENCES people_performance_kpi_targets(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE people_performance_responses ADD CONSTRAINT people_performance_responses_review_id_scope_fk FOREIGN KEY (review_id, tenant_id, company_id) REFERENCES people_performance_appraisals(id, tenant_id, company_id) ON DELETE RESTRICT"
    )

    create(
      constraint(:people_performance_descriptions, :people_performance_descriptions_version,
        check: "version > 0 AND position_version > 0"
      )
    )

    create(
      constraint(:people_performance_descriptions, :people_performance_descriptions_dates,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create(
      constraint(:people_performance_descriptions, :people_performance_descriptions_content,
        check:
          "length(btrim(code)) > 0 AND length(btrim(purpose)) > 0 AND length(btrim(responsibilities)) > 0 AND length(btrim(duties)) > 0 AND length(btrim(authority)) > 0 AND length(btrim(qualifications)) > 0 AND jsonb_typeof(competency_links->'profiles') = 'array' AND jsonb_array_length(competency_links->'profiles') > 0"
      )
    )

    create(
      constraint(:people_performance_descriptions, :people_performance_descriptions_workflow,
        check:
          "(status = 'draft' AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL)"
      )
    )

    create(
      constraint(:people_performance_kpi_definitions, :people_performance_kpi_definitions_version,
        check: "version > 0 AND precision BETWEEN 0 AND 8"
      )
    )

    create(
      constraint(:people_performance_kpi_definitions, :people_performance_kpi_definitions_content,
        check:
          "length(btrim(code)) > 0 AND length(btrim(name)) > 0 AND length(btrim(purpose)) > 0 AND length(btrim(unit)) > 0 AND length(btrim(measure)) > 0 AND length(btrim(source_reference)) > 0 AND length(btrim(calculation_version)) > 0 AND length(btrim(interpretation)) > 0"
      )
    )

    create(
      constraint(
        :people_performance_kpi_definitions,
        :people_performance_kpi_definitions_direction,
        check:
          "direction IN ('higher', 'lower', 'band', 'rubric') AND (direction <> 'rubric' OR COALESCE(length(btrim(rubric)), 0) > 0)"
      )
    )

    create(
      constraint(:people_performance_kpi_targets, :people_performance_kpi_targets_version,
        check: "version > 0 AND definition_version > 0"
      )
    )

    create(
      constraint(:people_performance_kpi_targets, :people_performance_kpi_targets_dates,
        check: "period_end >= period_start AND effective_from BETWEEN period_start AND period_end"
      )
    )

    create(
      constraint(:people_performance_kpi_targets, :people_performance_kpi_targets_content,
        check: "length(btrim(target)) > 0"
      )
    )

    create(
      constraint(:people_performance_kpi_targets, :people_performance_kpi_targets_workflow,
        check:
          "(status = 'proposed' AND review_note IS NULL AND reviewed_by_user_id IS NULL AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'reviewed' AND COALESCE(length(btrim(review_note)), 0) > 0 AND reviewed_by_user_id IS NOT NULL AND reviewed_by_user_id <> actor_user_id AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND NOT confidential AND COALESCE(length(btrim(review_note)), 0) > 0 AND reviewed_by_user_id IS NOT NULL AND reviewed_by_user_id <> actor_user_id AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL AND published_by_user_id <> actor_user_id)"
      )
    )

    create(
      constraint(:people_performance_kpi_targets, :people_performance_kpi_targets_correction,
        check:
          "(supersedes_id IS NULL AND version = 1 AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND version > 1 AND COALESCE(length(btrim(change_reason)), 0) > 0)"
      )
    )

    create(
      constraint(:people_performance_evidence, :people_performance_evidence_dates,
        check: "window_end >= window_start"
      )
    )

    create(
      constraint(:people_performance_evidence, :people_performance_evidence_content,
        check:
          "length(btrim(evidence)) > 0 AND length(btrim(source_reference)) > 0 AND length(btrim(source_version)) > 0"
      )
    )

    create(
      constraint(:people_performance_evidence, :people_performance_evidence_correction,
        check:
          "(supersedes_id IS NULL AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND COALESCE(length(btrim(change_reason)), 0) > 0)"
      )
    )

    create(
      constraint(:people_performance_appraisals, :people_performance_appraisals_dates,
        check: "period_end >= period_start AND cutoff_at::date >= period_end"
      )
    )

    create(
      constraint(:people_performance_appraisals, :people_performance_appraisals_content,
        check: "length(btrim(outcome)) > 0 AND length(btrim(rationale)) > 0"
      )
    )

    create(
      constraint(:people_performance_appraisals, :people_performance_appraisals_workflow,
        check:
          "(status = 'draft' AND released_at IS NULL AND released_by_user_id IS NULL) OR (status = 'released' AND released_at IS NOT NULL AND released_by_user_id IS NOT NULL AND released_by_user_id <> actor_user_id)"
      )
    )

    create(
      constraint(:people_performance_appraisals, :people_performance_appraisals_correction,
        check:
          "(supersedes_id IS NULL AND version = 1 AND change_reason IS NULL) OR (supersedes_id IS NOT NULL AND version > 1 AND COALESCE(length(btrim(change_reason)), 0) > 0)"
      )
    )

    create(
      constraint(:people_performance_responses, :people_performance_responses_content,
        check: "length(btrim(response)) > 0"
      )
    )

    [function | triggers] = String.split(guard_sql(), "CREATE TRIGGER")
    execute(function)
    for trigger <- triggers, do: execute("CREATE TRIGGER" <> trigger)
  end

  def down do
    drop(table(:people_performance_responses))
    drop(table(:people_performance_review_targets))
    drop(table(:people_performance_review_evidence))
    drop(table(:people_performance_appraisals))
    drop(table(:people_performance_evidence))
    drop(table(:people_performance_kpi_targets))
    drop(table(:people_performance_kpi_definitions))
    drop(table(:people_performance_descriptions))
    execute("DROP FUNCTION people_performance_guard()")
  end

  @doc false
  def guard_sql do
    """
    CREATE FUNCTION people_performance_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE parent record; prior record;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Performance history cannot be deleted' USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF TG_TABLE_NAME = 'people_performance_descriptions' AND (to_jsonb(OLD)->>'status') = 'draft'
           AND (to_jsonb(NEW)->>'status') = 'published' AND
           (to_jsonb(NEW) - ARRAY['status','published_at','published_by_user_id','updated_at']) =
           (to_jsonb(OLD) - ARRAY['status','published_at','published_by_user_id','updated_at']) THEN
          IF EXISTS (SELECT 1 FROM people_performance_descriptions d
            WHERE d.company_id = NEW.company_id AND d.position_id = NEW.position_id
              AND d.status = 'published' AND d.id <> NEW.id
              AND daterange(d.effective_from,d.effective_to,'[]') &&
                  daterange(NEW.effective_from,NEW.effective_to,'[]')) THEN
            RAISE EXCEPTION 'Description dates overlap' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        ELSIF TG_TABLE_NAME = 'people_performance_kpi_targets' AND
          (((to_jsonb(OLD)->>'status') = 'proposed' AND (to_jsonb(NEW)->>'status') = 'reviewed') OR
           ((to_jsonb(OLD)->>'status') = 'reviewed' AND (to_jsonb(NEW)->>'status') = 'published')) AND
          (to_jsonb(NEW) - ARRAY['status','review_note','reviewed_by_user_id','published_at','published_by_user_id','updated_at']) =
          (to_jsonb(OLD) - ARRAY['status','review_note','reviewed_by_user_id','published_at','published_by_user_id','updated_at']) THEN
          IF (to_jsonb(OLD)->>'status') = 'reviewed' AND (NEW.review_note, NEW.reviewed_by_user_id) IS DISTINCT FROM
              (OLD.review_note, OLD.reviewed_by_user_id) THEN
            RAISE EXCEPTION 'Reviewed rationale is immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        ELSIF TG_TABLE_NAME = 'people_performance_appraisals' AND (to_jsonb(OLD)->>'status') = 'draft'
          AND (to_jsonb(NEW)->>'status') = 'released' AND
          (to_jsonb(NEW) - ARRAY['status','released_at','released_by_user_id','updated_at']) =
          (to_jsonb(OLD) - ARRAY['status','released_at','released_by_user_id','updated_at']) THEN
          IF NOT EXISTS (SELECT 1 FROM people_performance_review_evidence WHERE review_id = NEW.id)
            OR NOT EXISTS (SELECT 1 FROM people_performance_review_targets WHERE review_id = NEW.id) THEN
            RAISE EXCEPTION 'Release requires pinned evidence and communicated targets' USING ERRCODE = '23514';
          END IF;
          IF NEW.cutoff_at > NEW.released_at THEN
            RAISE EXCEPTION 'Release cannot precede its cutoff' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Performance facts are immutable' USING ERRCODE = '23514';
      END IF;
      IF TG_TABLE_NAME = 'people_performance_descriptions' AND (to_jsonb(NEW)->>'status') <> 'draft'
        OR TG_TABLE_NAME = 'people_performance_kpi_targets' AND (to_jsonb(NEW)->>'status') <> 'proposed'
        OR TG_TABLE_NAME = 'people_performance_appraisals' AND (to_jsonb(NEW)->>'status') <> 'draft' THEN
        RAISE EXCEPTION 'New records must start pending' USING ERRCODE = '23514';
      END IF;
      IF TG_TABLE_NAME = 'people_performance_kpi_targets' THEN
        SELECT * INTO parent FROM people_performance_kpi_definitions WHERE id = NEW.definition_id;
        IF parent.version IS DISTINCT FROM NEW.definition_version THEN
          RAISE EXCEPTION 'Exact KPI definition version required' USING ERRCODE = '23514';
        END IF;
        IF NEW.supersedes_id IS NOT NULL THEN
          SELECT * INTO prior FROM people_performance_kpi_targets WHERE id = NEW.supersedes_id;
          IF prior.status <> 'published' OR
            (NEW.employee_id, NEW.definition_id, NEW.period_start, NEW.period_end, NEW.version) IS DISTINCT FROM
            (prior.employee_id, prior.definition_id, prior.period_start, prior.period_end, prior.version + 1)
            OR NEW.effective_from <= prior.effective_from THEN
            RAISE EXCEPTION 'Invalid target correction' USING ERRCODE = '23514';
          END IF;
        END IF;
      ELSIF TG_TABLE_NAME = 'people_performance_evidence' AND (to_jsonb(NEW)->>'supersedes_id') IS NOT NULL THEN
        SELECT * INTO prior FROM people_performance_evidence WHERE id = NEW.supersedes_id;
        IF (NEW.employee_id, NEW.window_start, NEW.window_end, NEW.source_reference) IS DISTINCT FROM
           (prior.employee_id, prior.window_start, prior.window_end, prior.source_reference) THEN
          RAISE EXCEPTION 'Invalid evidence correction' USING ERRCODE = '23514';
        END IF;
      ELSIF TG_TABLE_NAME = 'people_performance_appraisals' THEN
        SELECT * INTO parent FROM people_performance_descriptions WHERE id = NEW.description_id;
        IF parent.status <> 'published' OR parent.effective_from > NEW.period_start OR
          (parent.effective_to IS NOT NULL AND parent.effective_to < NEW.period_end) THEN
          RAISE EXCEPTION 'Published description must cover review period' USING ERRCODE = '23514';
        END IF;
        IF NEW.supersedes_id IS NOT NULL THEN
          SELECT * INTO prior FROM people_performance_appraisals WHERE id = NEW.supersedes_id;
          IF prior.status <> 'released' OR
            (NEW.employee_id, NEW.period_start, NEW.period_end, NEW.version) IS DISTINCT FROM
            (prior.employee_id, prior.period_start, prior.period_end, prior.version + 1) OR NEW.cutoff_at < prior.cutoff_at THEN
            RAISE EXCEPTION 'Invalid review correction' USING ERRCODE = '23514';
          END IF;
        END IF;
      ELSIF TG_TABLE_NAME IN ('people_performance_review_evidence','people_performance_review_targets','people_performance_responses') THEN
        SELECT * INTO parent FROM people_performance_appraisals WHERE id = NEW.review_id FOR UPDATE;
        IF TG_TABLE_NAME = 'people_performance_responses' THEN
          IF parent.status <> 'released' OR parent.employee_id <> NEW.employee_id THEN
            RAISE EXCEPTION 'Respond only to own released review' USING ERRCODE = '23514';
          END IF;
        ELSE
          IF parent.status <> 'draft' THEN
            RAISE EXCEPTION 'Released evidence cannot change' USING ERRCODE = '23514';
          END IF;
          IF TG_TABLE_NAME = 'people_performance_review_evidence' THEN
            SELECT * INTO prior FROM people_performance_evidence WHERE id = NEW.observation_id;
            IF prior.employee_id <> parent.employee_id OR prior.window_start < parent.period_start
              OR prior.window_end > parent.period_end OR prior.inserted_at > parent.cutoff_at THEN
              RAISE EXCEPTION 'Evidence outside review window' USING ERRCODE = '23514';
            END IF;
          ELSE
            SELECT * INTO prior FROM people_performance_kpi_targets WHERE id = NEW.target_id;
            IF prior.employee_id <> parent.employee_id OR prior.status <> 'published' OR prior.confidential
              OR prior.period_start <> parent.period_start OR prior.period_end <> parent.period_end
              OR prior.published_at > parent.cutoff_at THEN
              RAISE EXCEPTION 'Target outside review window' USING ERRCODE = '23514';
            END IF;
          END IF;
        END IF;
      END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER people_performance_descriptions_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_descriptions
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_kpi_definitions_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_kpi_definitions
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_kpi_targets_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_kpi_targets
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_evidence_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_evidence
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_appraisals_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_appraisals
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_review_evidence_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_review_evidence
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_review_targets_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_review_targets
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    CREATE TRIGGER people_performance_responses_guard BEFORE INSERT OR UPDATE OR DELETE ON people_performance_responses
      FOR EACH ROW EXECUTE FUNCTION people_performance_guard();
    """
  end
end
