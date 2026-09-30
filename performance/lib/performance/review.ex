defmodule Bilimbi.People.Performance.Review do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_reviews" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:employee_id, :integer)
    field(:description_id, :integer)
    field(:period_start, :date)
    field(:period_end, :date)
    field(:cutoff_at, :utc_datetime)
    field(:outcome, :string)
    field(:rationale, :string)
    field(:version, :integer)
    field(:supersedes_id, :integer)
    field(:change_reason, :string)
    field(:status, :string)
    field(:released_at, :utc_datetime)
    field(:released_by_user_id, :integer)
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :actor_user_id,
      :employee_id,
      :description_id,
      :period_start,
      :period_end,
      :cutoff_at,
      :outcome,
      :rationale,
      :version,
      :supersedes_id,
      :change_reason,
      :status,
      :released_at,
      :released_by_user_id
    ])
  end
end
