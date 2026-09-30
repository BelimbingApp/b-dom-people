defmodule Bilimbi.People.Payroll.Decision do
  @moduledoc false
  use Ecto.Schema
  schema "people_payroll_decisions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:run_id, :integer)
    field(:outcome, :string)
    field(:reason, :string)
    timestamps(type: :naive_datetime)
  end
end
