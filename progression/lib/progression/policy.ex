defmodule Bilimbi.People.Progression.Policy do
  @moduledoc false
  use Ecto.Schema

  schema "people_progression_policy_versions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:version, :integer)
    field(:name, :string)
    field(:effective_from, :date)
    field(:rules, :map)
    field(:status, :string)
    field(:actor_user_id, :integer)
    field(:published_by_user_id, :integer)
    field(:published_at, :utc_datetime)
    timestamps(type: :utc_datetime)
  end
end
