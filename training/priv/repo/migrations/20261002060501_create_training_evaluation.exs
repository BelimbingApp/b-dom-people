defmodule Bilimbi.People.Training.Migrations.CreateEvaluation do
  use Ecto.Migration

  def change do
    create table(:people_training_evaluation_policies) do
      common()
      add(:version, :integer, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date, null: false)
      add(:criteria, :map, null: false)
      add(:effectiveness_criteria, :map, null: false)
      add(:evaluation_days, :integer, null: false)
      add(:checkpoints, :map, null: false)
      add(:reminder_days, :integer, null: false)
      add(:reason, :text, null: false)
      timestamps()
    end

    create(
      unique_index(:people_training_evaluation_policies, [:company_id, :version],
        name: :people_training_evaluation_policy_version
      )
    )

    create(
      unique_index(:people_training_evaluation_policies, [:id, :tenant_id, :company_id],
        name: :people_training_evaluation_policy_scope
      )
    )

    create(
      constraint(:people_training_evaluation_policies, :people_training_evaluation_policy_values,
        check:
          "version > 0 AND effective_to >= effective_from AND evaluation_days >= 0 AND reminder_days >= 0 AND jsonb_array_length(criteria->'items') > 0 AND jsonb_array_length(effectiveness_criteria->'items') > 0 AND jsonb_array_length(checkpoints->'days') > 0 AND length(btrim(reason)) > 0"
      )
    )

    create table(:people_training_evaluation_reviews) do
      common()
      add(:policy_id, :bigint, null: false)
      add(:fact_id, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:checkpoint_days, :integer, null: false)
      add(:due_on, :date, null: false)
      timestamps()
    end

    create(
      unique_index(:people_training_evaluation_reviews, [:fact_id, :kind, :checkpoint_days],
        name: :people_training_evaluation_review_once
      )
    )

    create(
      unique_index(:people_training_evaluation_reviews, [:id, :tenant_id, :company_id],
        name: :people_training_evaluation_review_scope
      )
    )

    create(
      constraint(:people_training_evaluation_reviews, :people_training_evaluation_review_kind,
        check:
          "(kind = 'evaluation' AND checkpoint_days = 0) OR (kind = 'effectiveness' AND checkpoint_days > 0)"
      )
    )

    fk(:evaluation_reviews, :policy_id, :evaluation_policies)
    fk(:evaluation_reviews, :fact_id, :participation_facts)

    create table(:people_training_evaluation_answers) do
      common()
      add(:review_id, :bigint, null: false)
      add(:values, :map, null: false)
      add(:reason, :text, null: false)
      timestamps()
    end

    create(
      unique_index(:people_training_evaluation_answers, [:review_id],
        name: :people_training_evaluation_answer_once
      )
    )

    fk(:evaluation_answers, :review_id, :evaluation_reviews)

    create(
      constraint(:people_training_evaluation_answers, :people_training_evaluation_answer_reason,
        check: "length(btrim(reason)) > 0"
      )
    )

    create table(:people_training_evaluation_reminders) do
      common()
      add(:review_id, :bigint, null: false)
      add(:recipient_employee_id, :bigint, null: false)
      add(:available_on, :date, null: false)
      timestamps()
    end

    create(
      unique_index(:people_training_evaluation_reminders, [:review_id],
        name: :people_training_evaluation_reminder_once
      )
    )

    fk(:evaluation_reminders, :review_id, :evaluation_reviews)

    create table(:people_training_effectiveness_summaries) do
      common()
      add(:period_start, :date, null: false)
      add(:period_end, :date, null: false)
      add(:minimum_cohort, :integer, null: false)
      add(:status, :text, null: false)
      add(:groups, :map, null: false)
      timestamps()
    end

    create(
      unique_index(
        :people_training_effectiveness_summaries,
        [:tenant_id, :company_id, :period_start],
        name: :people_training_effectiveness_summary_period
      )
    )

    create(
      constraint(
        :people_training_effectiveness_summaries,
        :people_training_effectiveness_summary_values,
        check:
          "period_end >= period_start AND minimum_cohort >= 2 AND status IN ('current', 'suppressed') AND jsonb_typeof(groups->'items') = 'array'"
      )
    )

    execute(
      """
      CREATE FUNCTION people_training_criteria_valid(criteria jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
      DECLARE item jsonb; codes text[] := ARRAY[]::text[];
      BEGIN
        IF jsonb_typeof(criteria->'items') IS DISTINCT FROM 'array' THEN RETURN false; END IF;
        IF jsonb_array_length(criteria->'items') NOT BETWEEN 1 AND 50 THEN RETURN false; END IF;
        FOR item IN SELECT value FROM jsonb_array_elements(criteria->'items') LOOP
          IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
          IF (SELECT count(*) FROM jsonb_object_keys(item)) <> 4 OR NOT item ?& ARRAY['code','label','minimum','maximum'] THEN RETURN false; END IF;
          IF jsonb_typeof(item->'code') IS DISTINCT FROM 'string' OR (item->>'code') !~ '^[a-z][a-z0-9_]{0,79}$'
            OR jsonb_typeof(item->'label') IS DISTINCT FROM 'string' OR length(btrim(item->>'label')) NOT BETWEEN 1 AND 4000
            OR jsonb_typeof(item->'minimum') IS DISTINCT FROM 'number' OR (item->>'minimum') !~ '^-?[0-9]{1,5}$'
            OR jsonb_typeof(item->'maximum') IS DISTINCT FROM 'number' OR (item->>'maximum') !~ '^-?[0-9]{1,5}$' THEN RETURN false; END IF;
          IF (item->>'minimum')::integer < -10000 OR (item->>'maximum')::integer > 10000
            OR (item->>'minimum')::integer > (item->>'maximum')::integer OR (item->>'code') = ANY(codes) THEN RETURN false; END IF;
          codes := array_append(codes, item->>'code');
        END LOOP;
        RETURN true;
      END $$
      """,
      "DROP FUNCTION people_training_criteria_valid(jsonb)"
    )

    execute(
      """
      CREATE FUNCTION people_training_evaluation_review_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE fact people_training_participation_facts; policy people_training_evaluation_policies;
        session people_training_sessions; completed date; offset_days integer;
      BEGIN
        SELECT * INTO fact FROM people_training_participation_facts WHERE id = NEW.fact_id;
        SELECT * INTO session FROM people_training_sessions WHERE id = fact.session_id FOR UPDATE;
        SELECT * INTO policy FROM people_training_evaluation_policies WHERE id = NEW.policy_id;
        completed := (session.ends_at AT TIME ZONE 'UTC' AT TIME ZONE session.time_zone)::date;
        offset_days := CASE WHEN NEW.kind = 'evaluation' THEN policy.evaluation_days ELSE NEW.checkpoint_days END;
        IF fact.status IS DISTINCT FROM 'confirmed' OR completed NOT BETWEEN policy.effective_from AND policy.effective_to
          OR NEW.due_on <> completed + offset_days OR (NEW.kind = 'effectiveness' AND NOT (policy.checkpoints->'days') @> to_jsonb(ARRAY[NEW.checkpoint_days]))
          OR EXISTS (SELECT 1 FROM people_training_evaluation_reviews r JOIN people_training_participation_facts f ON f.id = r.fact_id
            WHERE f.session_id = fact.session_id AND f.employee_id = fact.employee_id AND r.kind = NEW.kind AND r.checkpoint_days = NEW.checkpoint_days) THEN
          RAISE EXCEPTION 'Invalid or duplicate review obligation' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_evaluation_review_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_evaluation_review_guard BEFORE INSERT ON people_training_evaluation_reviews FOR EACH ROW EXECUTE FUNCTION people_training_evaluation_review_guard()",
      "DROP TRIGGER people_training_evaluation_review_guard ON people_training_evaluation_reviews"
    )

    execute(
      """
      CREATE FUNCTION people_training_evaluation_answer_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE criteria jsonb; criterion jsonb; score jsonb;
      BEGIN
        SELECT CASE WHEN r.kind = 'evaluation' THEN p.criteria ELSE p.effectiveness_criteria END INTO criteria
          FROM people_training_evaluation_reviews r JOIN people_training_evaluation_policies p ON p.id = r.policy_id
          WHERE r.id = NEW.review_id;
        IF jsonb_typeof(NEW.values) IS DISTINCT FROM 'object' THEN
          RAISE EXCEPTION 'Answers must be criterion values' USING ERRCODE = '23514';
        END IF;
        IF (SELECT count(*) FROM jsonb_object_keys(NEW.values)) <> jsonb_array_length(criteria->'items') THEN
          RAISE EXCEPTION 'Answers must include exactly the criteria version' USING ERRCODE = '23514';
        END IF;
        FOR criterion IN SELECT value FROM jsonb_array_elements(criteria->'items') LOOP
          IF NOT NEW.values ? (criterion->>'code') THEN
            RAISE EXCEPTION 'Missing criterion' USING ERRCODE = '23514';
          END IF;
          score := NEW.values->(criterion->>'code');
          IF score <> 'null'::jsonb THEN
            IF jsonb_typeof(score) IS DISTINCT FROM 'number' OR score::text !~ '^-?[0-9]{1,5}$' THEN
              RAISE EXCEPTION 'Invalid criterion score' USING ERRCODE = '23514';
            END IF;
            IF score::text::integer NOT BETWEEN (criterion->>'minimum')::integer AND (criterion->>'maximum')::integer THEN
              RAISE EXCEPTION 'Score outside criterion bounds' USING ERRCODE = '23514';
            END IF;
          END IF;
        END LOOP;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_evaluation_answer_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_evaluation_answer_guard BEFORE INSERT ON people_training_evaluation_answers FOR EACH ROW EXECUTE FUNCTION people_training_evaluation_answer_guard()",
      "DROP TRIGGER people_training_evaluation_answer_guard ON people_training_evaluation_answers"
    )

    execute(
      """
      CREATE FUNCTION people_training_evaluation_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT people_training_criteria_valid(NEW.criteria) OR NOT people_training_criteria_valid(NEW.effectiveness_criteria)
          OR jsonb_typeof(NEW.checkpoints->'days') IS DISTINCT FROM 'array' THEN
          RAISE EXCEPTION 'Invalid criteria or checkpoints' USING ERRCODE = '23514';
        END IF;
        IF jsonb_array_length(NEW.checkpoints->'days') NOT BETWEEN 1 AND 24 OR
          EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.checkpoints->'days') d WHERE jsonb_typeof(d) <> 'number' OR d::text !~ '^[0-9]{1,4}$') THEN
          RAISE EXCEPTION 'Invalid checkpoints' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(NEW.checkpoints->'days') d WHERE d::integer NOT BETWEEN 1 AND 3650)
          OR (SELECT count(DISTINCT d) FROM jsonb_array_elements_text(NEW.checkpoints->'days') d) <> jsonb_array_length(NEW.checkpoints->'days') THEN
          RAISE EXCEPTION 'Checkpoints must be distinct positive day offsets' USING ERRCODE = '23514';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('people.training.evaluation:' || NEW.tenant_id || ':' || NEW.company_id, 0));
        IF EXISTS (SELECT 1 FROM people_training_evaluation_policies p WHERE p.company_id = NEW.company_id
            AND p.tenant_id = NEW.tenant_id AND p.effective_from <= NEW.effective_to AND p.effective_to >= NEW.effective_from) THEN
          RAISE EXCEPTION 'Evaluation policy periods overlap' USING ERRCODE = '23514';
        END IF;
        IF NEW.version <> (SELECT COALESCE(max(version), 0) + 1 FROM people_training_evaluation_policies
            WHERE tenant_id = NEW.tenant_id AND company_id = NEW.company_id) THEN
          RAISE EXCEPTION 'Policy must append next version' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_evaluation_policy_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_evaluation_policy_guard BEFORE INSERT ON people_training_evaluation_policies FOR EACH ROW EXECUTE FUNCTION people_training_evaluation_policy_guard()",
      "DROP TRIGGER people_training_evaluation_policy_guard ON people_training_evaluation_policies"
    )

    execute(
      """
      CREATE FUNCTION people_training_evaluation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'Evaluation history is immutable' USING ERRCODE = '23514';
      END $$
      """,
      "DROP FUNCTION people_training_evaluation_immutable()"
    )

    for suffix <-
          ~w(evaluation_policies evaluation_reviews evaluation_answers evaluation_reminders effectiveness_summaries) do
      execute(
        "CREATE TRIGGER people_training_#{suffix}_immutable BEFORE UPDATE OR DELETE ON people_training_#{suffix} FOR EACH ROW EXECUTE FUNCTION people_training_evaluation_immutable()",
        "DROP TRIGGER people_training_#{suffix}_immutable ON people_training_#{suffix}"
      )
    end
  end

  defp common do
    add(:tenant_id, :bigint, null: false)
    add(:company_id, :bigint, null: false)
    add(:actor_user_id, :bigint, null: false)
    add(:impersonator_id, :bigint)
  end

  defp fk(table, column, target) do
    execute(
      "ALTER TABLE people_training_#{table} ADD CONSTRAINT people_training_#{table}_#{column}_scope FOREIGN KEY (#{column}, tenant_id, company_id) REFERENCES people_training_#{target}(id, tenant_id, company_id)",
      "ALTER TABLE people_training_#{table} DROP CONSTRAINT people_training_#{table}_#{column}_scope"
    )
  end
end
