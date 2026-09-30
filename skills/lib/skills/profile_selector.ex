defmodule Bilimbi.People.Skills.ProfileSelector do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_profile_selectors" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:profile_id, :integer)
    field(:selector_type, :string)
    field(:position_id, :integer)
    timestamps(type: :naive_datetime)
  end
end
