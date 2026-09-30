defmodule Bilimbi.People.Payroll.Migrations.CreateOutputs do
  use Ecto.Migration

  def up do
    for name <- [:people_payroll_contributions, :people_payroll_calculations,
                 :people_payroll_decisions, :people_payroll_documents, :people_payroll_result_lines] do
      create table(name) do
        add(:tenant_id, :bigint, null: false)
        add(:company_id, :bigint, null: false)
        add(:created_by_actor_id, :bigint, null: false)
        add(:run_id, references(:people_payroll_runs, on_delete: :restrict), null: false)
        timestamps(type: :naive_datetime)
      end
      create(index(name, [:tenant_id, :company_id]))
      execute("CREATE TRIGGER #{name}_immutable BEFORE UPDATE OR DELETE ON #{name} FOR EACH ROW EXECUTE FUNCTION people_payroll_immutable()")
    end
    alter table(:people_payroll_contributions) do
      add(:employee_id, :bigint, null: false)
      add(:item_id, references(:people_payroll_items, on_delete: :restrict), null: false)
      add(:source_key, :string, size: 120, null: false)
      add(:evidence, :string, size: 500, null: false)
      add(:on_date, :date, null: false)
      add(:units, :decimal, precision: 20, scale: 6, null: false)
      add(:direction, :string, size: 20, null: false)
    end
    create(unique_index(:people_payroll_contributions, [:company_id, :source_key]))
    create(constraint(:people_payroll_contributions, :people_payroll_contributions_units, check: "units > 0"))
    create(constraint(:people_payroll_contributions, :people_payroll_contributions_direction, check: "direction IN ('earning', 'deduction', 'employer')"))
    alter table(:people_payroll_result_lines) do
      add(:contribution_id, references(:people_payroll_contributions, on_delete: :restrict), null: false)
      add(:employee_id, :bigint, null: false)
      add(:direction, :string, size: 20, null: false)
      add(:amount, :decimal, precision: 40, scale: 12, null: false)
    end
    create(unique_index(:people_payroll_result_lines, [:contribution_id]))
    create(constraint(:people_payroll_result_lines, :people_payroll_result_lines_amount, check: "amount >= 0"))
    alter table(:people_payroll_calculations) do
      add(:snapshot, :map, null: false)
      add(:digest, :string, size: 64, null: false)
    end
    create(unique_index(:people_payroll_calculations, [:run_id]))
    alter table(:people_payroll_decisions) do
      add(:outcome, :string, size: 20, null: false)
      add(:reason, :string, size: 500, null: false)
    end
    create(unique_index(:people_payroll_decisions, [:run_id]))
    create(constraint(:people_payroll_decisions, :people_payroll_decisions_outcome, check: "outcome IN ('approved', 'rejected')"))
    alter table(:people_payroll_documents) do
      add(:employee_id, :bigint)
      add(:artifact_id, :uuid, null: false)
      add(:kind, :string, size: 20, null: false)
    end
    create(constraint(:people_payroll_documents, :people_payroll_documents_kind, check: "(kind = 'report' AND employee_id IS NULL) OR (kind = 'payslip' AND employee_id IS NOT NULL)"))
    create(unique_index(:people_payroll_documents, [:artifact_id]))
    execute("""
    CREATE FUNCTION people_payroll_output_stage() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE r people_payroll_runs%ROWTYPE;
    DECLARE c people_payroll_calculations%ROWTYPE;
    BEGIN
      SELECT * INTO r FROM people_payroll_runs WHERE id = NEW.run_id FOR UPDATE;
      IF r.id IS NULL OR r.company_id <> NEW.company_id OR r.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'payroll output scope mismatch' USING ERRCODE = '23514';
      END IF;
      SELECT * INTO c FROM people_payroll_calculations WHERE run_id = NEW.run_id;
      IF TG_TABLE_NAME IN ('people_payroll_contributions', 'people_payroll_result_lines') AND c.id IS NOT NULL THEN
        RAISE EXCEPTION 'payroll calculation is frozen' USING ERRCODE = '23514';
      END IF;
      IF TG_TABLE_NAME IN ('people_payroll_calculations', 'people_payroll_result_lines') AND r.locked_at IS NULL THEN
        RAISE EXCEPTION 'payroll setup must be locked' USING ERRCODE = '23514';
      END IF;
      IF TG_TABLE_NAME = 'people_payroll_decisions' THEN
        IF c.id IS NULL OR NEW.created_by_actor_id IN (r.created_by_actor_id, c.created_by_actor_id) OR
          EXISTS (SELECT 1 FROM people_payroll_contributions WHERE run_id = NEW.run_id AND created_by_actor_id = NEW.created_by_actor_id) THEN
          RAISE EXCEPTION 'payroll independent decision required' USING ERRCODE = '23514';
        END IF;
      END IF;
      IF TG_TABLE_NAME = 'people_payroll_documents' AND NOT EXISTS (
        SELECT 1 FROM people_payroll_decisions WHERE run_id = NEW.run_id AND outcome = 'approved') THEN
        RAISE EXCEPTION 'payroll approval required' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END $$
    """)
    for name <- ~w(people_payroll_contributions people_payroll_result_lines people_payroll_calculations people_payroll_decisions people_payroll_documents) do
      execute("CREATE TRIGGER #{name}_stage BEFORE INSERT ON #{name} FOR EACH ROW EXECUTE FUNCTION people_payroll_output_stage()")
    end

  end

  def down do
    for name <- [:people_payroll_documents, :people_payroll_decisions,
                 :people_payroll_calculations, :people_payroll_result_lines, :people_payroll_contributions], do: drop(table(name))
    execute("DROP FUNCTION people_payroll_output_stage()")
  end
end
