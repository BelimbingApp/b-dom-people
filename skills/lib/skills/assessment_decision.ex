defmodule Bilimbi.People.Skills.AssessmentDecision do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_assessment_decisions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:assessment_id, :integer)
    field(:decision, :string)
    field(:actor_user_id, :integer)
    field(:note, :string)
    timestamps(type: :naive_datetime, updated_at: false)
  end
end
