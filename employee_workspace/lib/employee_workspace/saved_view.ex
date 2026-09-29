defmodule Bilimbi.People.EmployeeWorkspace.SavedView do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_employee_saved_views" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :actor_id, :integer
    field :name, :string
    field :search, :string
    field :status, :string
    timestamps(type: :naive_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :search, :status])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:search, max: 200)
    |> validate_length(:status, max: 40)
    |> unique_constraint([:company_id, :actor_id, :name])
  end
end
