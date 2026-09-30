defmodule Bilimbi.People.Leave.RequestEvent do
  @moduledoc false
  use Ecto.Schema

  schema "people_leave_request_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_id, :integer)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:actor_user_id, :integer)
    field(:note, :string)
    field(:occurred_at, :utc_datetime_usec)
  end
end
