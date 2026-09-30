defmodule Bilimbi.People.Skills.ReassessmentRequest do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_reassessment_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:skill_id, :integer)
    field(:reason, :string)
    field(:requested_by_user_id, :integer)
    field(:due_on, :date)
    field(:status, :string)
    field(:performed_by_user_id, :integer)
    field(:performed_at, :naive_datetime)
    field(:assessment_id, :integer)
    field(:cancelled_by_user_id, :integer)
    field(:cancelled_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end
end
