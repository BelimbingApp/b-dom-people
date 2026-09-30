defmodule Bilimbi.People.Skills.Migrations.AddAssessments do
  use Ecto.Migration

  def up do
    create table(:people_skill_assessments, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:skill_id, references(:people_skills, type: :bigint, on_delete: :restrict), null: false)

      add(:profile_id, references(:people_skill_profiles, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:scale_id, references(:people_skill_scales, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:required_level, :integer, null: false)
      add(:criticality, :string, size: 16, null: false)
      add(:weight_percent, :decimal, precision: 5, scale: 2, null: false)
      add(:mandatory, :boolean, null: false)
      add(:assessed_level, :integer, null: false)
      add(:gap, :integer, null: false)
      add(:priority_multiplier, :integer, null: false)
      add(:priority_score, :integer, null: false)
      add(:result_band, :string, size: 16, null: false)
      add(:method, :string, size: 80)
      add(:evidence, :string, size: 4000, null: false)
      add(:notes, :string, size: 2000)
      add(:assessed_on, :date, null: false)
      add(:valid_until, :date)
      add(:next_due_on, :date, null: false)
      add(:status, :string, size: 16, null: false)
      add(:assessor_user_id, :bigint, null: false)
      add(:reviewed_by_user_id, :bigint)
      add(:reviewed_at, :naive_datetime)
      add(:review_note, :string, size: 2000)
      add(:finalized_by_user_id, :bigint)
      add(:finalized_at, :naive_datetime)

      add(
        :supersedes_assessment_id,
        references(:people_skill_assessments, type: :bigint, on_delete: :restrict)
      )

      add(:request_key, :string, size: 80, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_assessments, [:id, :company_id, :employee_id, :skill_id],
        name: :people_skill_assessments_subject_unique
      )
    )

    create(
      unique_index(:people_skill_assessments, [:company_id, :assessor_user_id, :request_key],
        name: :people_skill_assessments_request_key_unique
      )
    )

    create(
      unique_index(:people_skill_assessments, [:supersedes_assessment_id],
        name: :people_skill_assessments_one_successor,
        where: "supersedes_assessment_id IS NOT NULL"
      )
    )

    create(
      index(:people_skill_assessments, [:company_id, :employee_id, :skill_id, :status],
        name: :people_skill_assessments_subject_status_index
      )
    )

    create(index(:people_skill_assessments, [:tenant_id, :company_id, :status]))

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_status,
        check: "status IN ('pending_review', 'verified', 'returned', 'finalized')"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_criticality,
        check: "criticality IN ('critical', 'essential', 'development')"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_band,
        check: "result_band IN ('exceeds', 'meets', 'minor_gap', 'major_gap', 'critical_gap')"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_levels,
        check:
          "required_level BETWEEN 0 AND 20 AND assessed_level BETWEEN 0 AND 20 " <>
            "AND gap = GREATEST(required_level - assessed_level, 0) " <>
            "AND priority_multiplier >= 0 AND priority_score = gap * priority_multiplier"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_evidence,
        check: "length(btrim(evidence)) > 0"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_dates,
        check: "valid_until IS NULL OR valid_until >= assessed_on"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_workflow,
        check:
          "(status = 'pending_review' AND reviewed_at IS NULL AND finalized_at IS NULL) OR " <>
            "(status = 'verified' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL " <>
            "AND finalized_at IS NULL) OR " <>
            "(status = 'returned' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL " <>
            "AND review_note IS NOT NULL AND finalized_at IS NULL) OR " <>
            "(status = 'finalized' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL " <>
            "AND finalized_at IS NOT NULL AND finalized_by_user_id IS NOT NULL)"
      )
    )

    create(
      constraint(:people_skill_assessments, :people_skill_assessments_independent,
        check:
          "(reviewed_by_user_id IS NULL OR reviewed_by_user_id <> assessor_user_id) AND " <>
            "(finalized_by_user_id IS NULL OR finalized_by_user_id <> assessor_user_id)"
      )
    )

    create table(:people_skill_assessment_decisions, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(
        :assessment_id,
        references(:people_skill_assessments, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:decision, :string, size: 16, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:note, :string, size: 2000)
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create(
      unique_index(:people_skill_assessment_decisions, [:assessment_id, :decision],
        name: :people_skill_assessment_decisions_once
      )
    )

    create(index(:people_skill_assessment_decisions, [:tenant_id, :company_id]))

    create(
      constraint(:people_skill_assessment_decisions, :people_skill_assessment_decisions_decision,
        check: "decision IN ('submitted', 'verified', 'returned', 'finalized')"
      )
    )

    create table(:people_skill_scores, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:skill_id, :bigint, null: false)
      add(:assessment_id, :bigint, null: false)
      add(:profile_id, :bigint, null: false)
      add(:required_level, :integer, null: false)
      add(:current_level, :integer, null: false)
      add(:gap, :integer, null: false)
      add(:criticality, :string, size: 16, null: false)
      add(:mandatory, :boolean, null: false)
      add(:priority_score, :integer, null: false)
      add(:assessed_on, :date, null: false)
      add(:valid_until, :date)
      add(:next_due_on, :date, null: false)
      timestamps(type: :naive_datetime)
    end

    execute("""
    ALTER TABLE people_skill_scores ADD CONSTRAINT people_skill_scores_assessment_fkey
    FOREIGN KEY (assessment_id, company_id, employee_id, skill_id)
    REFERENCES people_skill_assessments (id, company_id, employee_id, skill_id)
    ON DELETE RESTRICT
    """)

    create(
      unique_index(:people_skill_scores, [:company_id, :employee_id, :skill_id],
        name: :people_skill_scores_subject_unique
      )
    )

    create(index(:people_skill_scores, [:tenant_id, :company_id]))
    create(index(:people_skill_scores, [:company_id, :next_due_on]))

    create(
      constraint(:people_skill_scores, :people_skill_scores_gap,
        check: "gap = GREATEST(required_level - current_level, 0)"
      )
    )

    create table(:people_skill_reassessment_requests, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:skill_id, references(:people_skills, type: :bigint, on_delete: :restrict), null: false)
      add(:reason, :string, size: 1000, null: false)
      add(:requested_by_user_id, :bigint, null: false)
      add(:due_on, :date, null: false)
      add(:status, :string, size: 12, null: false)
      add(:performed_by_user_id, :bigint)
      add(:performed_at, :naive_datetime)

      add(
        :assessment_id,
        references(:people_skill_assessments, type: :bigint, on_delete: :restrict)
      )

      add(:cancelled_by_user_id, :bigint)
      add(:cancelled_at, :naive_datetime)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_reassessment_requests, [:company_id, :employee_id, :skill_id],
        name: :people_skill_reassessment_requests_one_open,
        where: "status = 'pending'"
      )
    )

    create(
      index(:people_skill_reassessment_requests, [:tenant_id, :company_id, :status],
        name: :people_skill_reassessment_requests_status_index
      )
    )

    create(
      constraint(:people_skill_reassessment_requests, :people_skill_reassessment_requests_state,
        check:
          "(status = 'pending' AND performed_at IS NULL AND cancelled_at IS NULL) OR " <>
            "(status = 'performed' AND performed_at IS NOT NULL AND " <>
            "performed_by_user_id IS NOT NULL AND assessment_id IS NOT NULL " <>
            "AND cancelled_at IS NULL) OR " <>
            "(status = 'cancelled' AND cancelled_at IS NOT NULL AND " <>
            "cancelled_by_user_id IS NOT NULL AND performed_at IS NULL)"
      )
    )

    create table(:people_skill_action_types, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 80, null: false)
      add(:name, :string, size: 160, null: false)
      add(:requires_provider, :boolean, null: false)
      add(:active, :boolean, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_action_types, [:company_id, :code],
        name: :people_skill_action_types_company_code_unique
      )
    )

    create(index(:people_skill_action_types, [:tenant_id, :company_id]))

    create table(:people_skill_actions, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:employee_name, :string, size: 200, null: false)
      add(:skill_id, references(:people_skills, type: :bigint, on_delete: :restrict), null: false)

      add(
        :source_assessment_id,
        references(:people_skill_assessments, type: :bigint, on_delete: :restrict)
      )

      add(
        :action_type_id,
        references(:people_skill_action_types, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:starting_level, :integer, null: false)
      add(:target_level, :integer, null: false)
      add(:gap_at_start, :integer, null: false)
      add(:criticality, :string, size: 16, null: false)
      add(:mandatory, :boolean, null: false)
      add(:priority_multiplier, :integer, null: false)
      add(:priority_score, :integer, null: false)
      add(:priority_explanation, :string, size: 300, null: false)
      add(:manual_reason, :string, size: 1000)
      add(:objective, :string, size: 2000, null: false)
      add(:intervention, :string, size: 2000, null: false)
      add(:expected_evidence, :string, size: 2000, null: false)
      add(:owner_employee_id, :bigint, null: false)
      add(:coordinator_employee_id, :bigint, null: false)
      add(:provider_employee_id, :bigint)
      add(:provider_name, :string, size: 160)
      add(:start_on, :date, null: false)
      add(:due_on, :date, null: false)
      add(:status, :string, size: 24, null: false)
      add(:closure, :string, size: 24, null: false)
      add(:approved_by_user_id, :bigint)
      add(:approved_at, :naive_datetime)
      add(:completed_at, :naive_datetime)
      add(:completion_evidence, :string, size: 2000)
      add(:reassessment_due_on, :date)

      add(
        :post_assessment_id,
        references(:people_skill_assessments, type: :bigint, on_delete: :restrict)
      )

      add(:post_level, :integer)
      add(:improvement, :integer)
      add(:next_steps, :string, size: 2000)
      add(:created_by_user_id, :bigint, null: false)
      add(:request_key, :string, size: 80, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_actions, [:company_id, :request_key],
        name: :people_skill_actions_request_key_unique
      )
    )

    create(
      unique_index(:people_skill_actions, [:source_assessment_id],
        name: :people_skill_actions_one_per_assessment,
        where: "source_assessment_id IS NOT NULL"
      )
    )

    create(index(:people_skill_actions, [:tenant_id, :company_id, :status, :due_on]))
    create(index(:people_skill_actions, [:company_id, :employee_id, :skill_id]))

    create(
      constraint(:people_skill_actions, :people_skill_actions_status,
        check:
          "status IN ('proposed', 'scheduled', 'not_started', 'in_progress', 'on_hold', " <>
            "'pending_reassessment', 'completed', 'cancelled')"
      )
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_closure,
        check:
          "closure IN ('open', 'pending_reassessment', 'closed_competent', " <>
            "'further_action_required', 'cancelled')"
      )
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_criticality,
        check: "criticality IN ('critical', 'essential', 'development')"
      )
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_levels,
        check:
          "starting_level BETWEEN 0 AND 20 AND target_level BETWEEN 0 AND 20 " <>
            "AND gap_at_start = GREATEST(target_level - starting_level, 0) " <>
            "AND priority_multiplier >= 0 AND priority_score = gap_at_start * priority_multiplier"
      )
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_dates, check: "due_on >= start_on")
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_basis,
        check: "source_assessment_id IS NOT NULL OR manual_reason IS NOT NULL"
      )
    )

    create(
      constraint(:people_skill_actions, :people_skill_actions_terminal,
        check:
          "(status = 'completed' AND closure IN ('closed_competent', 'further_action_required') " <>
            "AND post_assessment_id IS NOT NULL) OR " <>
            "(status = 'cancelled' AND closure = 'cancelled') OR " <>
            "(status = 'pending_reassessment' AND closure = 'pending_reassessment' " <>
            "AND completed_at IS NOT NULL) OR " <>
            "(status NOT IN ('completed', 'cancelled', 'pending_reassessment') " <>
            "AND closure = 'open')"
      )
    )

    create table(:people_skill_action_events, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:action_id, references(:people_skill_actions, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:event_type, :string, size: 32, null: false)
      add(:from_status, :string, size: 24)
      add(:to_status, :string, size: 24)
      add(:comment, :string, size: 2000)
      add(:evidence, :string, size: 2000)
      add(:actor_user_id, :bigint, null: false)
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create(index(:people_skill_action_events, [:action_id, :inserted_at]))
    create(index(:people_skill_action_events, [:tenant_id, :company_id]))

    create table(:people_skill_reminders, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:rule, :string, size: 24, null: false)
      add(:employee_id, :bigint)
      add(:skill_id, references(:people_skills, type: :bigint, on_delete: :restrict), null: false)
      add(:action_id, references(:people_skill_actions, type: :bigint, on_delete: :restrict))
      add(:period_key, :string, size: 12, null: false)
      add(:recipient_user_id, :bigint, null: false)
      add(:due_on, :date, null: false)
      add(:state, :string, size: 12, null: false)
      add(:failure, :string, size: 300)
      add(:sent_at, :naive_datetime)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(
        :people_skill_reminders,
        [
          :company_id,
          :rule,
          :employee_id,
          :skill_id,
          :action_id,
          :period_key,
          :recipient_user_id
        ],
        name: :people_skill_reminders_once,
        nulls_distinct: false
      )
    )

    create(
      index(:people_skill_reminders, [:tenant_id, :company_id, :recipient_user_id],
        name: :people_skill_reminders_recipient_index
      )
    )

    create(
      constraint(:people_skill_reminders, :people_skill_reminders_rule,
        check:
          "rule IN ('overdue_reassessment', 'expiring_certificate', 'overdue_action', " <>
            "'coverage_gap')"
      )
    )

    create(
      constraint(:people_skill_reminders, :people_skill_reminders_state,
        check: "state IN ('pending', 'sent', 'failed')"
      )
    )

    create(
      constraint(:people_skill_reminders, :people_skill_reminders_sent,
        check: "state <> 'sent' OR sent_at IS NOT NULL"
      )
    )

    guards()
  end

  def down do
    for table <-
          ~w(people_skill_reminders people_skill_action_events people_skill_actions
             people_skill_reassessment_requests people_skill_scores
             people_skill_assessment_decisions people_skill_assessments),
        do: execute("DROP TRIGGER IF EXISTS #{table}_guard ON #{table}")

    for function <-
          ~w(people_skill_reminders_guard people_skill_append_only people_skill_actions_guard
             people_skill_reassessment_requests_guard people_skill_scores_guard
             people_skill_assessments_guard),
        do: execute("DROP FUNCTION IF EXISTS #{function}()")

    drop(table(:people_skill_reminders))
    drop(table(:people_skill_action_events))
    drop(table(:people_skill_actions))
    drop(table(:people_skill_action_types))
    drop(table(:people_skill_reassessment_requests))
    drop(table(:people_skill_scores))
    drop(table(:people_skill_assessment_decisions))
    drop(table(:people_skill_assessments))
  end

  # The database refuses what the facade never does. Assessments are facts:
  # they enter as pending review, only the review and finalization columns move,
  # only along the permitted transitions, and nothing is deleted. Decisions and
  # action events are append-only. A score row can only mirror a finalized
  # assessment. Requests, actions and reminders leave a terminal state never.
  defp guards do
    execute("""
    CREATE FUNCTION people_skill_assessments_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      prior record;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'skill assessment % is a fact and is never deleted', OLD.id;
      END IF;
      IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending_review' THEN
          RAISE EXCEPTION 'a skill assessment enters as pending_review';
        END IF;
        IF NEW.supersedes_assessment_id IS NOT NULL THEN
          SELECT * INTO prior FROM people_skill_assessments
          WHERE id = NEW.supersedes_assessment_id;
          IF NOT FOUND OR prior.company_id <> NEW.company_id
             OR prior.employee_id <> NEW.employee_id OR prior.skill_id <> NEW.skill_id
             OR prior.status NOT IN ('returned', 'finalized') THEN
            RAISE EXCEPTION 'an assessment supersedes a returned or finalized assessment of the same employee and skill';
          END IF;
        END IF;
        RETURN NEW;
      END IF;
      IF NOT ((OLD.status = 'pending_review' AND NEW.status IN ('verified', 'returned'))
              OR (OLD.status = 'verified' AND NEW.status = 'finalized')) THEN
        RAISE EXCEPTION 'skill assessment % is % and cannot become %',
          OLD.id, OLD.status, NEW.status;
      END IF;
      IF NOT ((to_jsonb(NEW) - ARRAY['status', 'reviewed_by_user_id', 'reviewed_at',
                    'review_note', 'finalized_by_user_id', 'finalized_at', 'updated_at'])
                 = (to_jsonb(OLD) - ARRAY['status', 'reviewed_by_user_id', 'reviewed_at',
                    'review_note', 'finalized_by_user_id', 'finalized_at', 'updated_at'])) THEN
        RAISE EXCEPTION 'skill assessment % facts are immutable', OLD.id;
      END IF;
      IF OLD.status = 'verified' AND (
           NEW.reviewed_by_user_id IS DISTINCT FROM OLD.reviewed_by_user_id
           OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
           OR NEW.review_note IS DISTINCT FROM OLD.review_note) THEN
        RAISE EXCEPTION 'skill assessment % review is immutable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_assessments_guard
    BEFORE INSERT OR UPDATE OR DELETE ON people_skill_assessments
    FOR EACH ROW EXECUTE FUNCTION people_skill_assessments_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% rows are append-only', TG_TABLE_NAME;
    END;
    $$
    """)

    for table <- ~w(people_skill_assessment_decisions people_skill_action_events) do
      execute("""
      CREATE TRIGGER #{table}_guard BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION people_skill_append_only()
      """)
    end

    execute("""
    CREATE FUNCTION people_skill_scores_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      source record;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'skill score % is never deleted', OLD.id;
      END IF;
      SELECT * INTO source FROM people_skill_assessments WHERE id = NEW.assessment_id;
      IF NOT FOUND OR source.status <> 'finalized' THEN
        RAISE EXCEPTION 'a skill score mirrors a finalized assessment';
      END IF;
      IF NEW.profile_id <> source.profile_id OR NEW.required_level <> source.required_level
         OR NEW.current_level <> source.assessed_level OR NEW.gap <> source.gap
         OR NEW.criticality <> source.criticality OR NEW.mandatory <> source.mandatory
         OR NEW.priority_score <> source.priority_score
         OR NEW.assessed_on <> source.assessed_on
         OR NEW.valid_until IS DISTINCT FROM source.valid_until
         OR NEW.next_due_on <> source.next_due_on THEN
        RAISE EXCEPTION 'a skill score copies its assessment';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_scores_guard
    BEFORE INSERT OR UPDATE OR DELETE ON people_skill_scores
    FOR EACH ROW EXECUTE FUNCTION people_skill_scores_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_reassessment_requests_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'reassessment request % is never deleted', OLD.id;
      END IF;
      IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'reassessment request % is % and immutable', OLD.id, OLD.status;
      END IF;
      IF NEW.employee_id <> OLD.employee_id OR NEW.skill_id <> OLD.skill_id
         OR NEW.company_id <> OLD.company_id OR NEW.reason <> OLD.reason
         OR NEW.requested_by_user_id <> OLD.requested_by_user_id OR NEW.due_on <> OLD.due_on THEN
        RAISE EXCEPTION 'reassessment request % facts are immutable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_reassessment_requests_guard
    BEFORE UPDATE OR DELETE ON people_skill_reassessment_requests
    FOR EACH ROW EXECUTE FUNCTION people_skill_reassessment_requests_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_actions_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'skill action % is never deleted', OLD.id;
      END IF;
      IF OLD.status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'skill action % is % and immutable', OLD.id, OLD.status;
      END IF;
      IF NEW.company_id <> OLD.company_id OR NEW.tenant_id <> OLD.tenant_id
         OR NEW.employee_id <> OLD.employee_id OR NEW.skill_id <> OLD.skill_id
         OR NEW.source_assessment_id IS DISTINCT FROM OLD.source_assessment_id
         OR NEW.starting_level <> OLD.starting_level OR NEW.target_level <> OLD.target_level
         OR NEW.gap_at_start <> OLD.gap_at_start OR NEW.criticality <> OLD.criticality
         OR NEW.mandatory <> OLD.mandatory OR NEW.priority_score <> OLD.priority_score
         OR NEW.priority_explanation <> OLD.priority_explanation
         OR NEW.created_by_user_id <> OLD.created_by_user_id
         OR NEW.request_key <> OLD.request_key OR NEW.employee_name <> OLD.employee_name THEN
        RAISE EXCEPTION 'skill action % source snapshot is immutable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_actions_guard
    BEFORE UPDATE OR DELETE ON people_skill_actions
    FOR EACH ROW EXECUTE FUNCTION people_skill_actions_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_reminders_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'skill reminder % is never deleted', OLD.id;
      END IF;
      IF OLD.state = 'sent' THEN
        RAISE EXCEPTION 'skill reminder % was sent and is immutable', OLD.id;
      END IF;
      IF NEW.rule <> OLD.rule OR NEW.recipient_user_id <> OLD.recipient_user_id
         OR NEW.period_key <> OLD.period_key OR NEW.company_id <> OLD.company_id
         OR NEW.skill_id <> OLD.skill_id OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
         OR NEW.action_id IS DISTINCT FROM OLD.action_id OR NEW.due_on <> OLD.due_on THEN
        RAISE EXCEPTION 'skill reminder % identity is immutable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_reminders_guard
    BEFORE UPDATE OR DELETE ON people_skill_reminders
    FOR EACH ROW EXECUTE FUNCTION people_skill_reminders_guard()
    """)
  end
end
