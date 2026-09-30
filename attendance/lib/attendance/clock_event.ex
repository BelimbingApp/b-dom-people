defmodule Bilimbi.People.Attendance.ClockEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_attendance_clock_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:day_id, :integer)
    field(:event_key, :string)
    field(:event_type, :string)
    field(:source, :string)
    field(:occurred_at, :utc_datetime)
    field(:timezone, :string)
    field(:actor_user_id, :integer)
    field(:latitude, :decimal)
    field(:longitude, :decimal)
    field(:clocking_location_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_key,
      :event_type,
      :source,
      :occurred_at,
      :timezone,
      :actor_user_id,
      :latitude,
      :longitude,
      :clocking_location_id
    ])
    |> validate_required([
      :tenant_id,
      :company_id,
      :employee_id,
      :day_id,
      :event_key,
      :event_type,
      :source,
      :occurred_at,
      :timezone
    ])
    |> validate_inclusion(:event_type, ~w(in out break_in break_out))
    |> validate_length(:event_key, min: 1, max: 160)
    |> unique_constraint([:company_id, :source, :event_key],
      name: :people_attendance_events_source_key_unique
    )
  end
end
