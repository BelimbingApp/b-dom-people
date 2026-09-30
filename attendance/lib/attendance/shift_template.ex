defmodule Bilimbi.People.Attendance.ShiftTemplate do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_attendance_shift_templates" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    # Minutes past local midnight in the company's attendance time zone.
    field(:start_minute, :integer)
    field(:end_minute, :integer)
    field(:starts_at, :time, virtual: true)
    field(:ends_at, :time, virtual: true)
    field(:break_minutes, :integer, default: 0)
    field(:status, :string, default: "active")
    timestamps(type: :naive_datetime)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:code, :name, :starts_at, :ends_at, :break_minutes])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :code,
      :name,
      :starts_at,
      :ends_at,
      :break_minutes
    ])
    |> validate_length(:code, min: 1, max: 40)
    |> validate_format(:code, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:break_minutes, greater_than_or_equal_to: 0)
    |> put_minute(:starts_at, :start_minute)
    |> put_minute(:ends_at, :end_minute)
    |> validate_span()
    |> unique_constraint([:company_id, :code],
      name: :people_attendance_shift_templates_company_code_unique
    )
  end

  def status_changeset(template, status) when status in ~w(active retired),
    do: change(template, status: status)

  @doc "Scheduled minutes; an end at or before the start crosses midnight."
  def span_minutes(%{start_minute: start_minute, end_minute: end_minute}) do
    minutes = end_minute - start_minute
    if minutes > 0, do: minutes, else: minutes + 24 * 60
  end

  @doc "`HH:MM` for a minute past midnight."
  def clock(minute) when is_integer(minute),
    do: :io_lib.format("~2..0B:~2..0B", [div(minute, 60), rem(minute, 60)]) |> to_string()

  defp put_minute(changeset, virtual, field) do
    case get_change(changeset, virtual) do
      %Time{hour: hour, minute: minute} -> put_change(changeset, field, hour * 60 + minute)
      _ -> changeset
    end
  end

  defp validate_span(changeset) do
    start_minute = get_field(changeset, :start_minute)
    end_minute = get_field(changeset, :end_minute)
    break_minutes = get_field(changeset, :break_minutes)

    cond do
      is_nil(start_minute) or is_nil(end_minute) or is_nil(break_minutes) ->
        changeset

      start_minute == end_minute ->
        add_error(changeset, :ends_at, "must differ from the start")

      break_minutes >= span_minutes(%{start_minute: start_minute, end_minute: end_minute}) ->
        add_error(changeset, :break_minutes, "must be shorter than the shift")

      true ->
        changeset
    end
  end
end
