defmodule Bilimbi.People.Claims.Policy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.People.Claims.Money

  @amounts [:per_claim_limit, :monthly_limit, :yearly_limit, :receipt_threshold]

  schema "people_claim_policy_versions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:claim_type_id, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:currency, :string)
    field(:per_claim_limit, :decimal)
    field(:monthly_limit, :decimal)
    field(:yearly_limit, :decimal)
    field(:receipt_threshold, :decimal)
    timestamps(type: :naive_datetime)
  end

  def changeset(policy, attrs, allowed_currencies) do
    policy
    |> cast(attrs, [:effective_from, :effective_to, :currency | @amounts], empty_values: [""])
    |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:claim_type_id, :effective_from, :currency])
    |> validate_inclusion(:currency, allowed_currencies,
      message: "is not an allowed claim currency for this company"
    )
    |> validate_period()
    |> Money.validate_amount(:per_claim_limit, min: :positive)
    |> Money.validate_amount(:monthly_limit, min: :positive)
    |> Money.validate_amount(:yearly_limit, min: :positive)
    |> Money.validate_amount(:receipt_threshold, min: :zero)
  end

  def end_changeset(policy, effective_to) do
    policy
    |> cast(%{effective_to: effective_to}, [:effective_to])
    |> validate_required([:effective_to])
    |> validate_period()
  end

  defp validate_period(changeset) do
    from = get_field(changeset, :effective_from)
    to = get_field(changeset, :effective_to)

    if from && to && Date.compare(to, from) == :lt,
      do: add_error(changeset, :effective_to, "must not be before the start date"),
      else: changeset
  end
end
