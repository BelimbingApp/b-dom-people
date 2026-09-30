defmodule Bilimbi.People.Leave.Policy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_leave_policies" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:leave_type_id, :integer)
    field(:version, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:entitlement, :decimal)
    field(:actor_user_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:effective_from, :entitlement, :actor_user_id])
    |> validate_required([
      :tenant_id,
      :company_id,
      :leave_type_id,
      :version,
      :effective_from,
      :entitlement
    ])
    |> validate_number(:entitlement,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Decimal.new("9999.99")
    )
    |> unique_constraint([:leave_type_id, :effective_from],
      name: :people_leave_policies_type_from_unique
    )
    |> unique_constraint([:leave_type_id, :version],
      name: :people_leave_policies_type_version_unique
    )
  end
end
