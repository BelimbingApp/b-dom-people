defmodule Bilimbi.People.Leave.CarryForwardSkip do
  @moduledoc false
  use Ecto.Schema

  # One employee and type the latest carry-forward run of a year left open.
  schema "people_leave_carry_forward_skips" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:from_year, :integer)
    field(:employee_id, :integer)
    field(:employee_label, :string)
    field(:leave_type_id, :integer)
    field(:reason, :string)
    field(:blocking_year, :integer)
    field(:inserted_at, :naive_datetime)
  end
end
