defmodule Bilimbi.People.Skills.Score do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_scores" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:skill_id, :integer)
    field(:assessment_id, :integer)
    field(:profile_id, :integer)
    field(:required_level, :integer)
    field(:current_level, :integer)
    field(:gap, :integer)
    field(:criticality, :string)
    field(:mandatory, :boolean)
    field(:priority_score, :integer)
    field(:assessed_on, :date)
    field(:valid_until, :date)
    field(:next_due_on, :date)
    timestamps(type: :naive_datetime)
  end
end
