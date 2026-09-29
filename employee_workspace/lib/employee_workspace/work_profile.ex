defmodule Bilimbi.People.EmployeeWorkspace.WorkProfile do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_employee_work_profiles" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:work_location, :string)
    field(:work_arrangement, :string)
    field(:notes, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:work_location, :work_arrangement, :notes])
    |> validate_length(:work_location, max: 200)
    |> validate_length(:work_arrangement, max: 120)
    |> validate_length(:notes, max: 2_000)
    |> unique_constraint([:company_id, :employee_id])
  end
end
