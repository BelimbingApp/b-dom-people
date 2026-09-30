defmodule Bilimbi.People.Claims.AssignmentEmployee do
  @moduledoc false
  use Ecto.Schema

  schema "people_claim_assignment_employees" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:assignment_id, :integer)
    field(:employee_id, :integer)
    timestamps(type: :naive_datetime)
  end
end
