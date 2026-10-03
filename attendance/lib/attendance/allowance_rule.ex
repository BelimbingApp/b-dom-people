defmodule Bilimbi.People.Attendance.AllowanceRule do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_attendance_allowance_policies" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:unit, :string)
    field(:value, :decimal)
    field(:currency, :string)
    field(:effective_from, :date)
    field(:effective_until, :date)
    field(:status, :string, default: "active")
    timestamps(type: :naive_datetime)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :code,
      :name,
      :unit,
      :value,
      :currency,
      :effective_from,
      :effective_until
    ])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:unit, &String.trim/1)
    |> update_change(:currency, &(String.trim(&1) |> String.upcase()))
    |> validate_required([
      :tenant_id,
      :company_id,
      :code,
      :name,
      :unit,
      :value,
      :currency,
      :effective_from
    ])
    |> validate_length(:code, min: 1, max: 40)
    |> validate_format(:code, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:unit, min: 1, max: 32)
    |> validate_format(:unit, ~r/^[A-Za-z][A-Za-z0-9_.-]*$/)
    |> validate_number(:value, greater_than: 0)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_date_order()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :people_attendance_allowance_policies_company_code_from_unique
    )
  end

  def retire_changeset(rule), do: change(rule, status: "retired")

  def end_changeset(rule, until_date),
    do: rule |> change(effective_until: until_date) |> validate_date_order()

  defp validate_date_order(changeset) do
    from_date = get_field(changeset, :effective_from)
    until_date = get_field(changeset, :effective_until)

    if until_date && from_date && Date.compare(until_date, from_date) == :lt,
      do: add_error(changeset, :effective_until, "must be on or after the start date"),
      else: changeset
  end
end
