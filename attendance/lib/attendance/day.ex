defmodule Bilimbi.People.Attendance.Day do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_attendance_daily_summaries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:on_date, :date)
    field(:status, :string)
    field(:first_in_at, :utc_datetime)
    field(:last_out_at, :utc_datetime)
    field(:worked_minutes, :integer, default: 0)
    timestamps(type: :naive_datetime)
  end

  def changeset(day, attrs) do
    day
    |> cast(attrs, [:status, :first_in_at, :last_out_at, :worked_minutes])
    |> validate_required([:tenant_id, :company_id, :employee_id, :on_date, :status])
    |> validate_inclusion(:status, ~w(in_progress exception_pending ready_for_review))
    |> validate_number(:worked_minutes, greater_than_or_equal_to: 0)
    |> unique_constraint([:company_id, :employee_id, :on_date],
      name: :people_attendance_daily_summaries_company_employee_date_unique
    )
  end
end
