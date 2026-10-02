defmodule Bilimbi.People.Payroll.Document do
  @moduledoc false
  use Ecto.Schema

  schema "people_payroll_documents" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:created_by_actor_id, :integer)
    field(:run_id, :integer)
    field(:employee_id, :integer)
    field(:artifact_id, Ecto.UUID)
    field(:kind, :string)
    timestamps(type: :naive_datetime)
  end
end
