defmodule Bilimbi.People.Payroll.ResultLine do
  @moduledoc false
  use Ecto.Schema

  schema "people_payroll_calculation_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:run_id, :integer)
    field(:contribution_id, :integer)
    field(:employee_id, :integer)
    field(:direction, :string)
    field(:amount, :decimal)
    timestamps(type: :naive_datetime)
  end
end
