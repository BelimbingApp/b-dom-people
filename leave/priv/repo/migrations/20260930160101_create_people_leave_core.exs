defmodule Bilimbi.People.Leave.Migrations.CreateCore do
  use Ecto.Migration

  def up do
    create table(:people_leave_catalog_types, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 40, null: false)
      add(:name, :string, size: 120, null: false)
      add(:unit, :string, size: 8, null: false)
      add(:paid, :boolean, null: false)
      add(:status, :string, size: 16, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_leave_catalog_types, [:company_id, :code],
        name: :people_leave_catalog_types_company_code_unique
      )
    )

    create(index(:people_leave_catalog_types, [:tenant_id, :company_id]))

    create table(:people_leave_policies, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(
        :leave_type_id,
        references(:people_leave_catalog_types, type: :bigint, on_delete: :restrict), null: false)

      add(:version, :integer, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      add(:entitlement, :decimal, precision: 8, scale: 2, null: false)
      add(:actor_user_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_leave_policies, [:leave_type_id, :version],
        name: :people_leave_policies_type_version_unique
      )
    )

    create(
      unique_index(:people_leave_policies, [:leave_type_id, :effective_from],
        name: :people_leave_policies_type_from_unique
      )
    )

    create(index(:people_leave_policies, [:tenant_id, :company_id]))

    create(
      constraint(:people_leave_policies, :people_leave_policies_effective_range,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create(
      constraint(:people_leave_policies, :people_leave_policies_entitlement_non_negative,
        check: "entitlement >= 0"
      )
    )

    create table(:people_leave_ledger_entries, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)

      add(
        :leave_type_id,
        references(:people_leave_catalog_types, type: :bigint, on_delete: :restrict), null: false)

      add(:leave_year, :integer, null: false)
      add(:entry_type, :string, size: 24, null: false)
      add(:quantity, :decimal, precision: 10, scale: 2, null: false)
      add(:unit, :string, size: 8, null: false)

      add(:policy_id, references(:people_leave_policies, type: :bigint, on_delete: :restrict))

      add(:policy_version, :integer)
      add(:occurred_on, :date, null: false)
      add(:source, :string, size: 32, null: false)
      add(:entry_key, :string, size: 160, null: false)
      add(:actor_user_id, :bigint)
      add(:note, :string, size: 500)
      add(:inserted_at, :naive_datetime, null: false)
    end

    create(
      unique_index(:people_leave_ledger_entries, [:company_id, :source, :entry_key],
        name: :people_leave_ledger_entries_source_key_unique
      )
    )

    create(
      index(:people_leave_ledger_entries, [:tenant_id, :company_id, :employee_id, :leave_year])
    )

    # The ledger is append-only: a correction is a new entry, never an edit.
    execute("""
    CREATE FUNCTION people_leave_ledger_entries_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'people_leave_ledger_entries is append-only';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_leave_ledger_entries_append_only
    BEFORE UPDATE OR DELETE ON people_leave_ledger_entries
    FOR EACH ROW EXECUTE FUNCTION people_leave_ledger_entries_append_only()
    """)
  end

  def down do
    drop(table(:people_leave_ledger_entries))
    execute("DROP FUNCTION people_leave_ledger_entries_append_only()")
    drop(table(:people_leave_policies))
    drop(table(:people_leave_catalog_types))
  end
end
