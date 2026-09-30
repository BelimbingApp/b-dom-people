defmodule Bilimbi.People.Claims.AssignmentType do
  @moduledoc false
  use Ecto.Schema

  schema "people_claim_assignment_types" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:assignment_id, :integer)
    field(:claim_type_id, :integer)
    timestamps(type: :naive_datetime)
  end
end
