defmodule Bilimbi.People.Performance.Observation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_evidence" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:employee_id, :integer)
    field(:window_start, :date)
    field(:window_end, :date)
    field(:evidence, :string)
    field(:source_reference, :string)
    field(:source_version, :string)
    field(:supersedes_id, :integer)
    field(:change_reason, :string)
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :actor_user_id,
      :employee_id,
      :window_start,
      :window_end,
      :evidence,
      :source_reference,
      :source_version,
      :supersedes_id,
      :change_reason
    ])
  end
end
