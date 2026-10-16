defmodule Bilimbi.People.Workforce.EmploymentException do
  @moduledoc false

  use Ecto.Schema

  schema "people_workforce_employment_exceptions" do
    field(:tenant_id, :id)
    field(:company_id, :id)
    field(:legacy_employee_id, :id)
    field(:reason, :string)
    field(:detected_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end
end
