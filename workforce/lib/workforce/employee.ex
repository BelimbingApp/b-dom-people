defmodule Bilimbi.People.Workforce.Employee do
  @moduledoc "Public workforce employee facts; no login identity or People history."

  @enforce_keys [
    :reference,
    :company_reference,
    :platform_company_id,
    :workforce_company_id,
    :employee_number,
    :display_name
  ]
  defstruct [
    :reference,
    :company_reference,
    :platform_company_id,
    :workforce_company_id,
    :employee_number,
    :display_name,
    :email,
    :supervisor_reference
  ]

  @type t :: %__MODULE__{
          reference: Bilimbi.People.Workforce.Reference.t(),
          company_reference: Bilimbi.People.Workforce.Reference.t(),
          platform_company_id: pos_integer(),
          workforce_company_id: pos_integer(),
          employee_number: String.t(),
          display_name: String.t(),
          email: String.t() | nil,
          supervisor_reference: Bilimbi.People.Workforce.Reference.t() | nil
        }
end
