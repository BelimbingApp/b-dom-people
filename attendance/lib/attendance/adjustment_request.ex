defmodule Bilimbi.People.Attendance.AdjustmentRequest do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_attendance_corrections" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:request_key, :string)
    field(:event_type, :string)
    field(:proposed_at, :utc_datetime)
    field(:on_date, :date)
    field(:timezone, :string)
    field(:reason, :string)
    field(:status, :string, default: "pending")
    field(:requested_by_user_id, :integer)
    field(:decided_by_user_id, :integer)
    field(:decided_at, :utc_datetime)
    field(:decision_note, :string)
    field(:applied_clock_event_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:request_key, :event_type, :proposed_at, :on_date, :timezone, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :employee_id,
      :requested_by_user_id,
      :request_key,
      :event_type,
      :proposed_at,
      :on_date,
      :timezone,
      :reason
    ])
    |> validate_inclusion(:event_type, ~w(in out))
    |> validate_length(:request_key, min: 1, max: 160)
    |> validate_length(:reason, min: 1, max: 500)
    |> unique_constraint([:company_id, :request_key],
      name: :people_attendance_corrections_company_key_unique
    )
  end

  def decision_changeset(request, status, actor_user_id, note, applied_clock_event_id \\ nil)
      when status in ~w(approved rejected cancelled) do
    request
    |> change(
      status: status,
      decided_by_user_id: actor_user_id,
      decided_at: DateTime.utc_now() |> DateTime.truncate(:second),
      decision_note: note,
      applied_clock_event_id: applied_clock_event_id
    )
    |> validate_length(:decision_note, max: 500)
  end
end
