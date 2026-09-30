defmodule Bilimbi.People.Claims.RequestEvent do
  @moduledoc false
  use Ecto.Schema

  # Append-only status history; rows are never updated.
  schema "people_claim_request_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_id, :integer)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:actor_id, :integer)
    field(:reason, :string)
    field(:occurred_at, :naive_datetime)
  end
end
