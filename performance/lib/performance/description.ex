defmodule Bilimbi.People.Performance.Description do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_descriptions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:code, :string)
    field(:version, :integer)
    field(:position_id, :integer)
    field(:position_version, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:purpose, :string)
    field(:responsibilities, :string)
    field(:duties, :string)
    field(:authority, :string)
    field(:qualifications, :string)
    field(:competency_links, :map)
    field(:status, :string)
    field(:published_at, :utc_datetime)
    field(:published_by_user_id, :integer)
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :tenant_id,
      :company_id,
      :actor_user_id,
      :code,
      :version,
      :position_id,
      :position_version,
      :effective_from,
      :effective_to,
      :purpose,
      :responsibilities,
      :duties,
      :authority,
      :qualifications,
      :competency_links,
      :status,
      :published_at,
      :published_by_user_id
    ])
  end
end
