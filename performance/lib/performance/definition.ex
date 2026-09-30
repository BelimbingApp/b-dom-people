defmodule Bilimbi.People.Performance.Definition do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_performance_kpi_definitions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:actor_user_id, :integer)
    field(:code, :string)
    field(:version, :integer)
    field(:name, :string)
    field(:purpose, :string)
    field(:unit, :string)
    field(:measure, :string)
    field(:source_reference, :string)
    field(:calculation_version, :string)
    field(:direction, :string)
    field(:rubric, :string)
    field(:precision, :integer)
    field(:interpretation, :string)
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
      :name,
      :purpose,
      :unit,
      :measure,
      :source_reference,
      :calculation_version,
      :direction,
      :rubric,
      :precision,
      :interpretation
    ])
  end
end
