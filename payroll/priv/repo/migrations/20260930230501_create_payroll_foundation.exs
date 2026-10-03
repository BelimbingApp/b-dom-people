defmodule Bilimbi.People.Payroll.Migrations.CreateFoundation do
  use Ecto.Migration

  def up do
    for name <- [
          :people_payroll_classifications,
          :people_payroll_items,
          :people_payroll_pay_windows,
          :people_payroll_mappings,
          :people_payroll_setup_snapshots
        ] do
      create table(name) do
        add(:tenant_id, :bigint, null: false)
        add(:company_id, :bigint, null: false)
        add(:created_by_actor_id, :bigint, null: false)
        timestamps(type: :naive_datetime)
      end

      create(index(name, [:tenant_id, :company_id]))
    end

    alter table(:people_payroll_classifications) do
      add(:code, :string, size: 60, null: false)
      add(:name, :string, size: 120, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
    end

    alter table(:people_payroll_items) do
      add(:code, :string, size: 60, null: false)
      add(:name, :string, size: 120, null: false)

      add(:classification_id, references(:people_payroll_classifications, on_delete: :restrict),
        null: false
      )

      add(:currency, :string, size: 3, null: false)
      add(:amount, :decimal, precision: 20, scale: 6, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
    end

    alter table(:people_payroll_pay_windows) do
      add(:code, :string, size: 60, null: false)
      add(:starts_on, :date, null: false)
      add(:ends_on, :date, null: false)
      add(:pay_on, :date, null: false)
    end

    alter table(:people_payroll_mappings) do
      add(:source_kind, :string, size: 20, null: false)
      add(:source_key, :string, size: 100, null: false)
      add(:item_id, references(:people_payroll_items, on_delete: :restrict), null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
    end

    alter table(:people_payroll_setup_snapshots) do
      add(:period_id, references(:people_payroll_pay_windows, on_delete: :restrict), null: false)
      add(:country, :string, size: 100, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:snapshot, :map, null: false)
      add(:locked_at, :naive_datetime)
      add(:locked_by_actor_id, :bigint)
    end

    create(unique_index(:people_payroll_pay_windows, [:company_id, :code]))
    create(unique_index(:people_payroll_setup_snapshots, [:period_id, :currency]))

    for name <- [:people_payroll_classifications, :people_payroll_items, :people_payroll_mappings] do
      create(
        constraint(name, "#{name}_dates",
          check: "effective_to IS NULL OR effective_to >= effective_from"
        )
      )
    end

    create(
      constraint(:people_payroll_pay_windows, :people_payroll_pay_windows_dates,
        check: "ends_on >= starts_on AND pay_on >= ends_on"
      )
    )

    create(
      constraint(:people_payroll_items, :people_payroll_items_money,
        check: "amount >= 0 AND currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:people_payroll_mappings, :people_payroll_mappings_source,
        check: "source_kind IN ('leave', 'claims')"
      )
    )

    create(
      constraint(:people_payroll_setup_snapshots, :people_payroll_setup_snapshots_lock,
        check: "(locked_at IS NULL) = (locked_by_actor_id IS NULL)"
      )
    )

    create(
      constraint(:people_payroll_setup_snapshots, :people_payroll_setup_snapshots_currency,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    # Append-only definitions preserve old effective versions. The company
    # transaction lock serializes version overlap checks in the public API.
    execute("""
    CREATE FUNCTION people_payroll_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'payroll foundation records are immutable' USING ERRCODE = '23514';
    END $$
    """)

    for table <-
          ~w(people_payroll_classifications people_payroll_items people_payroll_pay_windows people_payroll_mappings) do
      execute(
        "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION people_payroll_immutable()"
      )
    end

    execute("""
    CREATE FUNCTION people_payroll_guard_run() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR OLD.locked_at IS NOT NULL THEN
        RAISE EXCEPTION 'payroll run cannot change' USING ERRCODE = '23514';
      END IF;
      IF (to_jsonb(NEW) - 'locked_at' - 'locked_by_actor_id' - 'updated_at') IS DISTINCT FROM
         (to_jsonb(OLD) - 'locked_at' - 'locked_by_actor_id' - 'updated_at') OR NEW.locked_at IS NULL THEN
        RAISE EXCEPTION 'only payroll run locking is permitted' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE TRIGGER people_payroll_setup_snapshots_guard BEFORE UPDATE OR DELETE ON people_payroll_setup_snapshots FOR EACH ROW EXECUTE FUNCTION people_payroll_guard_run()"
    )
  end

  def down do
    for name <- [
          :people_payroll_setup_snapshots,
          :people_payroll_mappings,
          :people_payroll_items,
          :people_payroll_classifications,
          :people_payroll_pay_windows
        ],
        do: drop(table(name))

    execute("DROP FUNCTION people_payroll_guard_run()")
    execute("DROP FUNCTION people_payroll_immutable()")
  end
end
