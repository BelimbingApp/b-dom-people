defmodule Bilimbi.People.Performance.Target do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_kpi_targets" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:definition_id, :integer)
    field(:definition_version, :integer)
    field(:employee_id, :integer)
    field(:target, :string)
    field(:period_start, :date)
    field(:period_end, :date)
    field(:effective_from, :date)
    field(:version, :integer)
    field(:supersedes_id, :integer)
    field(:change_reason, :string)
    field(:confidential, :boolean)
    field(:status, :string)
    field(:review_note, :string)
    field(:reviewed_by_user_id, :integer)
    field(:published_by_user_id, :integer)
    field(:published_at, :utc_datetime)
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :actor_user_id,
      :definition_id,
      :definition_version,
      :employee_id,
      :target,
      :period_start,
      :period_end,
      :effective_from,
      :version,
      :supersedes_id,
      :change_reason,
      :confidential,
      :status,
      :review_note,
      :reviewed_by_user_id,
      :published_by_user_id,
      :published_at
    ])
  end
end
