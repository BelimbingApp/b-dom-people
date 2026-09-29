defmodule Bilimbi.People.ReferenceData.Migrations.CreateReferenceData do
  use Ecto.Migration

  def up do
    create table(:people_reference_entries, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:kind, :string, size: 80, null: false)
      add(:code, :string, size: 100, null: false)
      add(:label, :string, size: 200, null: false)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_reference_entries, [:company_id, :kind, :code],
        name: :people_reference_entries_company_kind_code_unique
      )
    )

    create(index(:people_reference_entries, [:tenant_id, :company_id]))

    create table(:people_reference_aliases, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:entry_id, references(:people_reference_entries, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:kind, :string, size: 80, null: false)
      add(:label, :string, size: 200, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_reference_aliases, [:company_id, :kind, :label],
        name: :people_reference_aliases_company_kind_label_unique
      )
    )

    create(index(:people_reference_aliases, [:tenant_id, :company_id, :entry_id]))

    create table(:people_calendar_exceptions, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:on_date, :date, null: false)
      add(:label, :string, size: 200, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_calendar_exceptions, [:company_id, :on_date, :label],
        name: :people_calendar_exceptions_company_date_label_unique
      )
    )

    create(index(:people_calendar_exceptions, [:tenant_id, :company_id, :on_date]))
  end

  def down do
    drop(table(:people_calendar_exceptions))
    drop(table(:people_reference_aliases))
    drop(table(:people_reference_entries))
  end
end
