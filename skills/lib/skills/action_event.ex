defmodule Bilimbi.People.Skills.ActionEvent do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_action_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:action_id, :integer)
    field(:event_type, :string)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:comment, :string)
    field(:evidence, :string)
    field(:actor_user_id, :integer)
    timestamps(type: :naive_datetime, updated_at: false)
  end
end
