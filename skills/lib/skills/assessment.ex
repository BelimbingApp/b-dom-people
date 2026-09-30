defmodule Bilimbi.People.Skills.Assessment do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_assessments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:skill_id, :integer)
    field(:profile_id, :integer)
    field(:scale_id, :integer)
    field(:required_level, :integer)
    field(:criticality, :string)
    field(:weight_percent, :decimal)
    field(:mandatory, :boolean)
    field(:assessed_level, :integer)
    field(:gap, :integer)
    field(:priority_multiplier, :integer)
    field(:priority_score, :integer)
    field(:result_band, :string)
    field(:method, :string)
    field(:evidence, :string)
    field(:notes, :string)
    field(:assessed_on, :date)
    field(:valid_until, :date)
    field(:next_due_on, :date)
    field(:status, :string)
    field(:assessor_user_id, :integer)
    field(:reviewed_by_user_id, :integer)
    field(:reviewed_at, :naive_datetime)
    field(:review_note, :string)
    field(:finalized_by_user_id, :integer)
    field(:finalized_at, :naive_datetime)
    field(:supersedes_assessment_id, :integer)
    field(:request_key, :string)
    timestamps(type: :naive_datetime)
  end
end
