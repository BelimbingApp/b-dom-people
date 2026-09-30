defmodule Bilimbi.People.Skills.Reminder do
  @moduledoc false
  use Ecto.Schema

  schema "people_skill_reminders" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:rule, :string)
    field(:employee_id, :integer)
    field(:skill_id, :integer)
    field(:action_id, :integer)
    field(:period_key, :string)
    field(:recipient_user_id, :integer)
    field(:due_on, :date)
    field(:state, :string)
    field(:failure, :string)
    field(:sent_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end
end
