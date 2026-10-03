defmodule Bilimbi.People.Training.Migrations.CreateParticipation do
  use Ecto.Migration

  def change do
    create(unique_index(:people_training_session_runs, [:id, :tenant_id, :company_id]))

    create table(:people_training_attendance_facts) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:session_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:revision, :integer, null: false)
      add(:status, :string, size: 20, null: false)
      add(:reason, :text, null: false)
      add(:import_key, :string, size: 160, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:impersonator_id, :bigint)
      timestamps()
    end

    create(
      unique_index(:people_training_attendance_facts, [:tenant_id, :company_id, :import_key],
        name: :people_training_attendance_facts_import
      )
    )

    create(
      unique_index(:people_training_attendance_facts, [:session_id, :employee_id, :revision],
        name: :people_training_attendance_facts_revision
      )
    )

    create(
      unique_index(:people_training_attendance_facts, [:id, :tenant_id, :company_id],
        name: :people_training_facts_scope
      )
    )

    create(
      constraint(
        :people_training_attendance_facts,
        :people_training_attendance_facts_values,
        check:
          "revision > 0 AND employee_id > 0 AND status IN ('confirmed', 'absent') AND length(btrim(reason)) > 0 AND length(btrim(import_key)) > 0"
      )
    )

    execute(
      "ALTER TABLE people_training_attendance_facts ADD CONSTRAINT people_training_attendance_facts_session_scope FOREIGN KEY (session_id, tenant_id, company_id) REFERENCES people_training_session_runs(id, tenant_id, company_id)",
      "ALTER TABLE people_training_attendance_facts DROP CONSTRAINT people_training_attendance_facts_session_scope"
    )

    create table(:people_training_evidence) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:fact_id, :bigint, null: false)
      # Base owns bytes and tombstones. Keep the durable document ID without a
      # cross-owner table coupling; every access uses the Base public API.
      add(:artifact_id, :uuid, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:impersonator_id, :bigint)
      timestamps()
    end

    create(unique_index(:people_training_evidence, [:artifact_id]))
    create(index(:people_training_evidence, [:tenant_id, :company_id, :fact_id]))

    execute(
      "ALTER TABLE people_training_evidence ADD CONSTRAINT people_training_evidence_fact_scope FOREIGN KEY (fact_id, tenant_id, company_id) REFERENCES people_training_attendance_facts(id, tenant_id, company_id)",
      "ALTER TABLE people_training_evidence DROP CONSTRAINT people_training_evidence_fact_scope"
    )

    execute(
      """
      CREATE FUNCTION people_training_fact_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE maximum integer; previous_revision integer; occupied integer; prior_status text;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'Training facts are append only' USING ERRCODE = '23514';
        END IF;
        SELECT capacity INTO maximum FROM people_training_session_runs
          WHERE id = NEW.session_id AND tenant_id = NEW.tenant_id AND company_id = NEW.company_id FOR UPDATE;
        SELECT revision, status INTO previous_revision, prior_status FROM people_training_attendance_facts
          WHERE session_id = NEW.session_id AND employee_id = NEW.employee_id ORDER BY revision DESC LIMIT 1;
        IF NEW.revision <> COALESCE(previous_revision, 0) + 1 THEN
          RAISE EXCEPTION 'Training correction must append next revision' USING ERRCODE = '23514';
        END IF;
        IF NEW.status = 'confirmed' AND prior_status IS DISTINCT FROM 'confirmed' THEN
          SELECT count(*) INTO occupied FROM (
            SELECT DISTINCT ON (employee_id) status FROM people_training_attendance_facts
            WHERE session_id = NEW.session_id ORDER BY employee_id, revision DESC
          ) latest WHERE status = 'confirmed';
          IF occupied >= maximum THEN
            RAISE EXCEPTION 'Training session capacity exceeded' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_fact_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_fact_guard BEFORE INSERT OR UPDATE OR DELETE ON people_training_attendance_facts FOR EACH ROW EXECUTE FUNCTION people_training_fact_guard()",
      "DROP TRIGGER people_training_fact_guard ON people_training_attendance_facts"
    )

    execute(
      """
      CREATE FUNCTION people_training_evidence_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'Training evidence provenance is append only' USING ERRCODE = '23514';
      END $$
      """,
      "DROP FUNCTION people_training_evidence_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_evidence_guard BEFORE UPDATE OR DELETE ON people_training_evidence FOR EACH ROW EXECUTE FUNCTION people_training_evidence_guard()",
      "DROP TRIGGER people_training_evidence_guard ON people_training_evidence"
    )

    execute(
      """
      CREATE FUNCTION people_training_participation_capacity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE occupied integer;
      BEGIN
        SELECT count(*) INTO occupied FROM (
          SELECT DISTINCT ON (employee_id) status FROM people_training_attendance_facts
          WHERE session_id = NEW.id ORDER BY employee_id, revision DESC
        ) latest WHERE status = 'confirmed';
        IF NEW.capacity < occupied THEN
          RAISE EXCEPTION 'Session capacity is below confirmed attendance' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_participation_capacity_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_participation_capacity_guard BEFORE UPDATE ON people_training_session_runs FOR EACH ROW EXECUTE FUNCTION people_training_participation_capacity_guard()",
      "DROP TRIGGER people_training_participation_capacity_guard ON people_training_session_runs"
    )
  end
end
