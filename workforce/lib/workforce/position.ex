defmodule Bilimbi.People.Workforce.Position do
  @moduledoc "Public native workforce position projection supplied by Organisation."

  @enforce_keys [
    :reference,
    :company_reference,
    :platform_company_id,
    :workforce_company_id,
    :code,
    :vacant?
  ]
  defstruct [
    :reference,
    :company_reference,
    :platform_company_id,
    :workforce_company_id,
    :code,
    :parent_reference,
    :title,
    :version,
    :assignments,
    :assignments_incomplete?,
    :vacant?
  ]
end
