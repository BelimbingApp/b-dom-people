defmodule Bilimbi.People.Leave.LedgerEntry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Later slices add request-driven types (taken, cancelled) and year-end
  # types (carried forward, expired) with their own writers.
  @entry_types ~w(entitlement opening adjustment)

  schema "people_leave_ledger_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:leave_type_id, :integer)
    field(:leave_year, :integer)
    field(:entry_type, :string)
    field(:quantity, :decimal)
    field(:unit, :string)
    field(:policy_id, :integer)
    field(:policy_version, :integer)
    field(:occurred_on, :date)
    field(:source, :string)
    field(:entry_key, :string)
    field(:actor_user_id, :integer)
    field(:note, :string)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def entry_types, do: @entry_types

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :leave_year,
      :entry_type,
      :quantity,
      :unit,
      :policy_id,
      :policy_version,
      :occurred_on,
      :source,
      :entry_key,
      :actor_user_id,
      :note
    ])
    |> validate_required([
      :tenant_id,
      :company_id,
      :employee_id,
      :leave_type_id,
      :leave_year,
      :entry_type,
      :quantity,
      :unit,
      :occurred_on,
      :source,
      :entry_key
    ])
    |> validate_inclusion(:entry_type, @entry_types)
    |> validate_length(:source, min: 1, max: 32)
    |> validate_length(:entry_key, min: 1, max: 160)
    |> validate_length(:note, max: 500)
    |> unique_constraint([:company_id, :source, :entry_key],
      name: :people_leave_ledger_entries_source_key_unique
    )
  end
end
