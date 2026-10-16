defmodule Bilimbi.People.Workforce.EmploymentRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending probation active inactive terminated)
  @facts [:employee_number, :employment_type, :status, :employment_start, :employment_end]

  schema "people_workforce_employments" do
    field(:tenant_id, :id)
    field(:company_id, :id)
    field(:legacy_employee_id, :id)
    field(:person_id, :id)
    field(:affiliation_id, :id)
    field(:employee_number, :string)
    field(:employment_type, :string)
    field(:status, :string)
    field(:employment_start, :date)
    field(:employment_end, :date)
    field(:metadata, Bilimbi.Base.Database.Json)
    field(:legacy_created_at, :naive_datetime)
    field(:claimed_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end

  @doc "The HR facts People owns and a People write may change."
  def facts, do: @facts

  @doc """
  Copies a legacy Core Employee row verbatim. Nothing is validated beyond
  presence, so a historical value Core never constrained is kept, not refused.
  """
  def claim_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :legacy_employee_id,
      :person_id,
      :affiliation_id,
      :metadata,
      :legacy_created_at,
      :claimed_at | @facts
    ])
    |> validate_required([
      :tenant_id,
      :company_id,
      :legacy_employee_id,
      :person_id,
      :affiliation_id,
      :employee_number,
      :employment_type,
      :status,
      :claimed_at
    ])
  end

  @doc "Validates a People change to the employment facts."
  def update_changeset(record, attrs) do
    record
    |> cast(attrs, @facts)
    |> update_change(:employee_number, &trim/1)
    |> update_change(:employment_type, &trim/1)
    |> validate_required([:employee_number, :employment_type, :status])
    |> validate_length(:employee_number, min: 1, max: 255)
    |> validate_length(:employment_type, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_period()
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  defp validate_period(changeset) do
    start_date = get_field(changeset, :employment_start)
    end_date = get_field(changeset, :employment_end)

    if start_date && end_date && Date.before?(end_date, start_date),
      do: add_error(changeset, :employment_end, "must be on or after employment start"),
      else: changeset
  end
end
