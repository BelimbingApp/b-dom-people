defmodule Bilimbi.People.EmployeeWorkspace.Access do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_employee_accesses" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:portal_enabled, :boolean, default: false)
    field(:reason, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:portal_enabled, :reason])
    |> validate_required([:portal_enabled])
    |> validate_length(:reason, max: 2_000)
    |> unique_constraint([:company_id, :employee_id])
  end
end
