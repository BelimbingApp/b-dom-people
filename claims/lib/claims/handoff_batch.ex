defmodule Bilimbi.People.Claims.HandoffBatch do
  @moduledoc false
  use Ecto.Schema

  # Immutable record of approved claims handed off in one currency. Rows are
  # never updated; each request keeps a reference to its batch.
  schema "people_claim_handoff_batches" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:currency, :string)
    field(:request_count, :integer)
    field(:total_amount, :decimal)
    field(:created_by_actor_id, :integer)
    field(:created_at, :naive_datetime)
  end
end
