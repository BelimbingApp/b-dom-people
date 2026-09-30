defmodule Bilimbi.People.Attendance.RosterEntry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Query

  # `kind` and `shift_template_id` hold the planner's working value;
  # `published_*` hold what employees see. `none` is a planned removal that
  # publishing applies.
  schema "people_attendance_roster_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:on_date, :date)
    field(:kind, :string)
    field(:shift_template_id, :integer)
    field(:published_kind, :string)
    field(:published_shift_template_id, :integer)
    field(:published_at, :utc_datetime)
    field(:published_by_user_id, :integer)
    field(:revision, :integer, default: 1)
    field(:updated_by_user_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def pending?(%__MODULE__{} = entry),
    do:
      entry.kind != (entry.published_kind || "none") or
        entry.shift_template_id != entry.published_shift_template_id

  @doc "Narrows `query` to entries for which `pending?/1` holds."
  def where_pending(query) do
    where(
      query,
      [e],
      fragment(
        "? <> COALESCE(?, 'none') OR ? IS DISTINCT FROM ?",
        e.kind,
        e.published_kind,
        e.shift_template_id,
        e.published_shift_template_id
      )
    )
  end
end
