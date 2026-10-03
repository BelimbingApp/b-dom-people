defmodule Bilimbi.People.Leave.Request do
  @moduledoc false
  use Ecto.Schema

  @statuses ~w(pending approved rejected cancelled)
  @day_parts ~w(full am pm hours)

  schema "people_leave_applications" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:leave_type_id, :integer)
    field(:leave_year, :integer)
    field(:starts_on, :date)
    field(:ends_on, :date)
    field(:day_part, :string)
    field(:quantity, :decimal)
    field(:unit, :string)
    field(:status, :string)
    field(:reason, :string)
    field(:request_key, :string)
    field(:requested_by_user_id, :integer)
    field(:decided_by_user_id, :integer)
    field(:decided_at, :utc_datetime_usec)
    field(:decision_note, :string)
    field(:cancelled_by_user_id, :integer)
    field(:cancelled_at, :utc_datetime_usec)
    timestamps(type: :naive_datetime)
  end

  def statuses, do: @statuses
  def day_parts, do: @day_parts
end
