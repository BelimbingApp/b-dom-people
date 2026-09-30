defmodule Bilimbi.People.Claims.Assignment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # A named, effective-dated group that makes assigned-only claim types
  # available to its employees.
  schema "people_claim_assignments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:effective_to, :date)
    timestamps(type: :naive_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:code, :name, :effective_from, :effective_to], empty_values: [""])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:code, :name, :effective_from])
    |> validate_length(:code, max: 60)
    |> validate_length(:name, max: 120)
    |> validate_period()
    |> unique_constraint([:company_id, :code], name: :people_claim_assignments_company_code_unique)
  end

  def end_changeset(assignment, effective_to) do
    assignment
    |> cast(%{effective_to: effective_to}, [:effective_to])
    |> validate_required([:effective_to])
    |> validate_period()
  end

  defp validate_period(changeset) do
    from = get_field(changeset, :effective_from)
    to = get_field(changeset, :effective_to)

    if from && to && Date.compare(to, from) == :lt,
      do: add_error(changeset, :effective_to, "must not be before the start date"),
      else: changeset
  end
end
