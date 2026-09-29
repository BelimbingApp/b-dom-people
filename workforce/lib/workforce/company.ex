defmodule Bilimbi.People.Workforce.Company do
  @moduledoc "Public native workforce company read model."

  @enforce_keys [:reference, :platform_company_id, :workforce_company_id, :name, :code]
  defstruct [:reference, :platform_company_id, :workforce_company_id, :name, :code]

  @type t :: %__MODULE__{
          reference: Bilimbi.People.Workforce.Reference.t(),
          platform_company_id: pos_integer(),
          workforce_company_id: pos_integer(),
          name: String.t(),
          code: String.t()
        }
end
