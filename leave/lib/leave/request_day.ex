defmodule Bilimbi.People.Leave.RequestDay do
  @moduledoc false
  use Ecto.Schema

  # A live request holds the half-day slots of each counted date; the partial
  # unique indexes on active slots make overlapping live requests impossible.
  schema "people_leave_request_days" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:request_id, :integer)
    field(:on_date, :date)
    field(:am, :boolean)
    field(:pm, :boolean)
    field(:quantity, :decimal)
    field(:active, :boolean)
  end
end
