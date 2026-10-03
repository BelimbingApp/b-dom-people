defmodule Bilimbi.People.Leave.LeaveType do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @units ~w(day hour)

  schema "people_leave_catalog_types" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:unit, :string)
    field(:paid, :boolean)
    field(:balance_required, :boolean, default: true)
    field(:status, :string)
    timestamps(type: :naive_datetime)
  end

  def units, do: @units

  def changeset(type, attrs) do
    type
    |> cast(attrs, [:code, :name, :unit, :paid, :balance_required, :status])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :code,
      :name,
      :unit,
      :paid,
      :balance_required,
      :status
    ])
    |> validate_length(:code, min: 1, max: 40)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:unit, @units)
    |> validate_inclusion(:status, ~w(active archived))
    |> unique_constraint([:company_id, :code],
      name: :people_leave_catalog_types_company_code_unique
    )
  end
end
