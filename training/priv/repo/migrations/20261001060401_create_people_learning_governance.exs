defmodule Bilimbi.People.Training.Migrations.CreateLearningGovernance do
  use Ecto.Migration

  def change do
    create table(:people_training_budget_policies) do
      common()
      add(:currency, :text, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date, null: false)
      add(:amount, :decimal, precision: 18, scale: 4, null: false)
      add(:reason, :text, null: false)
      add(:supersedes_id, :bigint)
      timestamps()
    end

    scope_index(:people_training_budget_policies)
    create(unique_index(:people_training_budget_policies, [:supersedes_id]))
    fk(:people_training_budget_policies, :supersedes_id, :people_training_budget_policies)

    create(
      constraint(:people_training_budget_policies, :people_training_budget_policies_dates,
        check: "effective_to >= effective_from"
      )
    )

    create(
      constraint(:people_training_budget_policies, :people_training_budget_policies_amount,
        check: "amount >= 0"
      )
    )

    create table(:people_training_needs) do
      common()
      add(:employee_id, :bigint, null: false)
      add(:course_id, :bigint)
      add(:need, :text, null: false)
      add(:objective, :text, null: false)
      add(:expected_result, :text, null: false)
      add(:proposed_on, :date, null: false)
      add(:estimated_cost, :decimal, precision: 18, scale: 4, null: false)
      add(:currency, :text, null: false)
      add(:status, :text, null: false)
      add(:budget_policy_id, :bigint)
      add(:approved_cost, :decimal, precision: 18, scale: 4)
      timestamps()
    end

    scope_index(:people_training_needs)

    create(
      constraint(:people_training_needs, :people_training_needs_status,
        check:
          "status IN ('draft', 'pending_hod', 'pending_hr', 'pending_approval', 'approved', 'rejected', 'cancelled')"
      )
    )

    create(index(:people_training_needs, [:tenant_id, :company_id, :employee_id]))
    fk(:people_training_needs, :course_id, :people_training_courses)
    fk(:people_training_needs, :budget_policy_id, :people_training_budget_policies)

    create(
      constraint(:people_training_needs, :people_training_needs_cost,
        check: "estimated_cost >= 0 AND (approved_cost IS NULL OR approved_cost >= 0)"
      )
    )

    create(
      constraint(:people_training_needs, :people_training_needs_approval,
        check:
          "(status = 'approved' AND budget_policy_id IS NOT NULL AND approved_cost IS NOT NULL) OR (status <> 'approved' AND budget_policy_id IS NULL AND approved_cost IS NULL)"
      )
    )

    create table(:people_training_team_plans) do
      common()
      add(:plan_key, :text, null: false)
      add(:version, :integer, null: false)
      add(:manager_employee_id, :bigint, null: false)
      add(:period_start, :date, null: false)
      add(:period_end, :date, null: false)
      add(:objectives, :text, null: false)
      add(:status, :text, null: false)
      add(:prior_plan_id, :bigint)
      add(:reason, :text, null: false)
      timestamps()
    end

    scope_index(:people_training_team_plans)

    create(
      constraint(:people_training_team_plans, :people_training_team_plans_status,
        check:
          "status IN ('draft', 'submitted', 'approved', 'rejected', 'cancelled', 'superseded')"
      )
    )

    create(unique_index(:people_training_team_plans, [:company_id, :plan_key, :version]))
    fk(:people_training_team_plans, :prior_plan_id, :people_training_team_plans)

    create(
      constraint(:people_training_team_plans, :people_training_team_plans_dates,
        check: "period_end >= period_start"
      )
    )

    create(
      constraint(:people_training_team_plans, :people_training_team_plans_version, check: "version > 0")
    )

    create table(:people_training_team_plan_items) do
      common()
      add(:plan_id, :bigint, null: false)
      add(:request_id, :bigint)

      for field <- [
            :need,
            :expected_result,
            :target_cohort,
            :responsible_owner,
            :intended_timing,
            :evaluation_approach
          ],
          do: add(field, :text, null: false)

      timestamps()
    end

    fk(:people_training_team_plan_items, :plan_id, :people_training_team_plans)
    fk(:people_training_team_plan_items, :request_id, :people_training_needs)

    for {table, parent, target} <- [
          {:people_training_need_decisions, :request_id, :people_training_needs},
          {:people_training_plan_decisions, :plan_id, :people_training_team_plans}
        ] do
      create table(table) do
        common()
        add(parent, :bigint, null: false)

        for field <- [:action, :from_status, :to_status, :reason],
            do: add(field, :text, null: false)

        timestamps()
      end

      fk(table, parent, target)
    end

    execute(
      """
      CREATE FUNCTION people_training_budget_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('people.training:' || NEW.tenant_id || ':' || NEW.company_id, 0));
        IF EXISTS (SELECT 1 FROM people_training_budget_policies p WHERE p.tenant_id = NEW.tenant_id AND p.company_id = NEW.company_id AND p.currency = NEW.currency AND p.effective_from <= NEW.effective_to AND p.effective_to >= NEW.effective_from AND p.id IS DISTINCT FROM NEW.supersedes_id AND NOT EXISTS (SELECT 1 FROM people_training_budget_policies s WHERE s.supersedes_id = p.id)) THEN
          RAISE EXCEPTION 'Budget periods overlap' USING ERRCODE = '23514';
        END IF;
        IF NEW.supersedes_id IS NOT NULL AND (
          NOT EXISTS (SELECT 1 FROM people_training_budget_policies p WHERE p.id = NEW.supersedes_id AND p.tenant_id = NEW.tenant_id AND p.company_id = NEW.company_id AND p.currency = NEW.currency) OR
          EXISTS (SELECT 1 FROM people_training_needs r JOIN people_training_budget_policies p ON p.id = NEW.supersedes_id WHERE r.tenant_id = NEW.tenant_id AND r.company_id = NEW.company_id AND r.currency = NEW.currency AND r.status = 'approved' AND r.proposed_on BETWEEN p.effective_from AND p.effective_to AND r.proposed_on NOT BETWEEN NEW.effective_from AND NEW.effective_to)
        ) THEN
          RAISE EXCEPTION 'Invalid budget correction' USING ERRCODE = '23514';
        END IF;
        IF (SELECT COALESCE(sum(approved_cost), 0) FROM people_training_needs r WHERE r.tenant_id = NEW.tenant_id AND r.company_id = NEW.company_id AND r.currency = NEW.currency AND r.status = 'approved' AND r.proposed_on BETWEEN NEW.effective_from AND NEW.effective_to) > NEW.amount THEN
          RAISE EXCEPTION 'Budget below commitments' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_budget_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_budget_guard BEFORE INSERT ON people_training_budget_policies FOR EACH ROW EXECUTE FUNCTION people_training_budget_guard()",
      "DROP TRIGGER people_training_budget_guard ON people_training_budget_policies"
    )

    execute(
      """
      CREATE FUNCTION people_training_commitment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE p people_training_budget_policies%ROWTYPE; spent numeric;
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('people.training:' || NEW.tenant_id || ':' || NEW.company_id, 0));
        IF NEW.status = 'approved' THEN
          SELECT * INTO p FROM people_training_budget_policies WHERE id = NEW.budget_policy_id AND tenant_id = NEW.tenant_id AND company_id = NEW.company_id AND NOT EXISTS (SELECT 1 FROM people_training_budget_policies s WHERE s.supersedes_id = NEW.budget_policy_id);
          SELECT COALESCE(sum(approved_cost), 0) INTO spent FROM people_training_needs WHERE id <> NEW.id AND tenant_id = NEW.tenant_id AND company_id = NEW.company_id AND currency = NEW.currency AND status = 'approved' AND proposed_on BETWEEN p.effective_from AND p.effective_to;
          IF p.id IS NULL OR p.currency <> NEW.currency OR NEW.proposed_on NOT BETWEEN p.effective_from AND p.effective_to OR NEW.approved_cost IS DISTINCT FROM NEW.estimated_cost OR spent + NEW.approved_cost > p.amount THEN
            RAISE EXCEPTION 'Approval violates effective budget' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_commitment_guard()"
    )

    execute(
      "CREATE TRIGGER people_training_commitment_guard BEFORE INSERT OR UPDATE ON people_training_needs FOR EACH ROW EXECUTE FUNCTION people_training_commitment_guard()",
      "DROP TRIGGER people_training_commitment_guard ON people_training_needs"
    )

    # Governance facts and decision history cannot be rewritten through SQL.
    execute(
      """
      CREATE FUNCTION people_training_governance_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'Learning governance facts are immutable' USING ERRCODE = '23514';
      END $$
      """,
      "DROP FUNCTION people_training_governance_immutable()"
    )

    for table <- [
          :people_training_budget_policies,
          :people_training_team_plan_items,
          :people_training_need_decisions,
          :people_training_plan_decisions
        ] do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION people_training_governance_immutable()",
        "DROP TRIGGER #{table}_immutable ON #{table}"
      )
    end

    execute(
      """
      CREATE FUNCTION people_training_governance_guard() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - ARRAY['status','updated_at','budget_policy_id','approved_cost']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','updated_at','budget_policy_id','approved_cost']) THEN
          RAISE EXCEPTION 'Learning content cannot be rewritten' USING ERRCODE = '23514';
        END IF;
        IF OLD.status IN ('approved','rejected','cancelled','superseded') AND NOT (TG_TABLE_NAME = 'people_training_team_plans' AND OLD.status = 'approved' AND NEW.status = 'superseded') THEN
          RAISE EXCEPTION 'Learning decision is terminal' USING ERRCODE = '23514';
        END IF;
        IF TG_TABLE_NAME = 'people_training_needs' AND NOT (
          (OLD.status = 'draft' AND NEW.status IN ('pending_hod', 'cancelled')) OR
          (OLD.status = 'pending_hod' AND NEW.status IN ('pending_hr', 'rejected', 'cancelled')) OR
          (OLD.status = 'pending_hr' AND NEW.status IN ('pending_approval', 'rejected', 'cancelled')) OR
          (OLD.status = 'pending_approval' AND NEW.status IN ('approved', 'rejected', 'cancelled'))
        ) THEN
          RAISE EXCEPTION 'Invalid request transition' USING ERRCODE = '23514';
        END IF;
        IF TG_TABLE_NAME = 'people_training_team_plans' AND NOT (
          (OLD.status = 'draft' AND NEW.status IN ('submitted', 'cancelled')) OR
          (OLD.status = 'submitted' AND NEW.status IN ('approved', 'rejected')) OR
          (OLD.status = 'approved' AND NEW.status = 'superseded')
        ) THEN
          RAISE EXCEPTION 'Invalid plan transition' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION people_training_governance_guard()"
    )

    for table <- [:people_training_needs, :people_training_team_plans] do
      execute(
        "CREATE TRIGGER #{table}_guard BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION people_training_governance_guard()",
        "DROP TRIGGER #{table}_guard ON #{table}"
      )
    end
  end

  defp common do
    add(:tenant_id, :bigint, null: false)
    add(:company_id, :bigint, null: false)
    add(:actor_user_id, :bigint, null: false)
    add(:impersonator_id, :bigint)
  end

  defp scope_index(table), do: create(unique_index(table, [:id, :tenant_id, :company_id]))

  defp fk(table, column, target) do
    name = "#{table}_#{column}_scope"

    execute(
      "ALTER TABLE #{table} ADD CONSTRAINT #{name} FOREIGN KEY (#{column}, tenant_id, company_id) REFERENCES #{target} (id, tenant_id, company_id)",
      "ALTER TABLE #{table} DROP CONSTRAINT #{name}"
    )
  end
end
