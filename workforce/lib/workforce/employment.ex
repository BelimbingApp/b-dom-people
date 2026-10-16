defmodule Bilimbi.People.Workforce.Employment do
  @moduledoc """
  People's employment facts for one employee: number, type, status and dates.

  `employee_id` is the legacy Core Employee ID every People module keys on.
  `person_id` and `affiliation_id` reference the Core Person and the person's
  affiliation with the employer company; identity and contact facts stay in
  Core and are not copied here.

  `source` says where the facts come from:

    * `:people` - claimed into People; the values are People's.
    * `:legacy_drift` - claimed, but Core's deprecated HR path changed a fact
      afterwards. The values are Core's newer ones until a reconcile adopts
      them. It occurs only while Core does not route those writes to People
      (`EmploymentOwner`); once it does, a claimed row is always `:people`.
    * `:core_legacy` - not claimed yet; the values are Core's. `person_id` and
      `affiliation_id` are nil when Core has no person mapping for the row.
  """

  @enforce_keys [
    :employee_id,
    :platform_company_id,
    :employee_number,
    :employment_type,
    :status,
    :source
  ]
  defstruct [
    :employee_id,
    :platform_company_id,
    :person_id,
    :affiliation_id,
    :employee_number,
    :employment_type,
    :status,
    :employment_start,
    :employment_end,
    :metadata,
    :source
  ]

  @type source :: :people | :legacy_drift | :core_legacy

  @type t :: %__MODULE__{
          employee_id: pos_integer(),
          platform_company_id: pos_integer(),
          person_id: pos_integer() | nil,
          affiliation_id: pos_integer() | nil,
          employee_number: String.t(),
          employment_type: String.t(),
          status: String.t(),
          employment_start: Date.t() | nil,
          employment_end: Date.t() | nil,
          metadata: map() | list() | nil,
          source: source()
        }
end
