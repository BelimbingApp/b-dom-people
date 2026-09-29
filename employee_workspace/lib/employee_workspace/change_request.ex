defmodule Bilimbi.People.EmployeeWorkspace.ChangeRequest do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(full_name short_name email mobile_number)a

  schema "people_employee_change_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:field, :string)
    field(:proposed_value, :string)
    field(:reason, :string)
    field(:status, :string, default: "pending")
    field(:requested_by_actor_id, :integer)
    field(:reviewed_by_actor_id, :integer)
    field(:reviewed_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end

  def fields, do: Enum.map(@fields, &Atom.to_string/1)

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:field, :proposed_value, :reason])
    |> validate_required([:field, :proposed_value])
    |> validate_inclusion(:field, fields())
    |> validate_length(:proposed_value, max: 500)
    |> validate_length(:reason, max: 2_000)
  end

  def review_changeset(record, status, actor_id) when status in ["approved", "rejected"] do
    change(record,
      status: status,
      reviewed_by_actor_id: actor_id,
      reviewed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    )
  end
end
