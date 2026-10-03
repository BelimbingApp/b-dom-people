defmodule Bilimbi.People.Payroll.Run do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_payroll_setup_snapshots" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:period_id, :integer)
    field(:country, :string)
    field(:currency, :string)
    field(:snapshot, :map)
    field(:locked_at, :naive_datetime)
    field(:locked_by_actor_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    changeset =
      record
      |> cast(attrs, [:period_id, :country, :currency, :snapshot])
      |> validate_required([:period_id, :country, :currency, :snapshot])

    changeset
  end
end
