defmodule Bilimbi.People.Organisation.Migrations.CreatePeoplePositions do
  use Ecto.Migration

  def change do
    create table(:people_positions) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:code, :string, null: false)
      add(:parent_id, references(:people_positions, type: :bigint, on_delete: :restrict))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:people_positions, [:company_id, :code]))
    create(unique_index(:people_positions, [:id, :company_id]))
    create(index(:people_positions, [:company_id, :parent_id]))

    create(
      constraint(:people_positions, :people_positions_not_own_parent,
        check: "parent_id IS NULL OR parent_id <> id"
      )
    )

    execute(
      "ALTER TABLE people_positions ADD CONSTRAINT people_positions_parent_company_fk FOREIGN KEY (parent_id, company_id) REFERENCES people_positions (id, company_id) ON DELETE RESTRICT",
      "ALTER TABLE people_positions DROP CONSTRAINT people_positions_parent_company_fk"
    )

    create table(:people_position_revisions) do
      add(:position_id, references(:people_positions, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:version, :integer, null: false)
      add(:title, :string, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:people_position_revisions, [:position_id, :version]))
    create(index(:people_position_revisions, [:position_id, :effective_from]))

    create(
      constraint(:people_position_revisions, :people_position_revisions_positive_version,
        check: "version > 0"
      )
    )

    create(
      constraint(:people_position_revisions, :people_position_revisions_valid_interval,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create table(:people_position_placements) do
      add(:position_id, references(:people_positions, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:employee_id, references(:employees, type: :bigint, on_delete: :restrict), null: false)
      add(:kind, :string, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:people_position_placements, [:position_id, :effective_from]))
    create(index(:people_position_placements, [:employee_id, :effective_from]))

    create(
      constraint(:people_position_placements, :people_position_placements_kind,
        check: "kind IN ('substantive', 'acting', 'concurrent')"
      )
    )

    create(
      constraint(:people_position_placements, :people_position_placements_valid_interval,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "SELECT 1")

    execute(
      "ALTER TABLE people_position_revisions ADD CONSTRAINT people_position_revisions_no_overlap EXCLUDE USING gist (position_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&)",
      "ALTER TABLE people_position_revisions DROP CONSTRAINT people_position_revisions_no_overlap"
    )

    execute(
      "ALTER TABLE people_position_placements ADD CONSTRAINT people_position_placements_one_substantive EXCLUDE USING gist (position_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&) WHERE (kind = 'substantive')",
      "ALTER TABLE people_position_placements DROP CONSTRAINT people_position_placements_one_substantive"
    )
  end
end
