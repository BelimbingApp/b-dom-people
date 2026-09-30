defmodule Bilimbi.People.Payroll.Calculation do
  @moduledoc false
  use Ecto.Schema
  schema "people_payroll_calculations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:run_id, :integer)
    field(:snapshot, :map)
    field(:digest, :string)
    timestamps(type: :naive_datetime)
  end
end
