defmodule Bilimbi.People.Claims.Request do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.People.Claims.Money

  schema "people_claim_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:employee_id, :integer)
    field(:claim_type_id, :integer)
    field(:claim_policy_id, :integer)
    field(:incurred_on, :date)
    field(:amount, :decimal)
    field(:currency, :string)
    field(:description, :string)
    field(:receipt_number, :string)
    field(:status, :string)
    field(:duplicate_confirmed, :boolean, default: false)
    field(:submitted_by_actor_id, :integer)
    field(:submitted_at, :naive_datetime)
    field(:withdrawn_by_actor_id, :integer)
    field(:withdrawn_at, :naive_datetime)
    field(:confirm_duplicate, :boolean, virtual: true, default: false)
    timestamps(type: :naive_datetime)
  end

  @doc "Casts and validates the submitted facts before policy evaluation."
  def submission_changeset(request, attrs) do
    request
    |> cast(
      attrs,
      [
        :claim_type_id,
        :incurred_on,
        :amount,
        :currency,
        :description,
        :receipt_number,
        :confirm_duplicate
      ],
      empty_values: [""]
    )
    |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:description, &blank_to_nil/1)
    |> update_change(:receipt_number, &normalize_receipt/1)
    |> validate_required([:claim_type_id, :incurred_on, :amount, :currency])
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_length(:description, max: 500)
    |> validate_length(:receipt_number, max: 100)
    |> Money.validate_amount(:amount, min: :positive)
    |> unique_constraint([:company_id, :employee_id, :receipt_number],
      name: :people_claim_requests_receipt_unique
    )
  end

  def withdraw_changeset(request, actor_id, now) do
    change(request, status: "withdrawn", withdrawn_by_actor_id: actor_id, withdrawn_at: now)
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Receipt references compare case-insensitively and ignore surrounding and
  # repeated whitespace, so the partial unique index sees one canonical form.
  defp normalize_receipt(value) do
    case value |> String.split() |> Enum.join(" ") |> String.upcase() do
      "" -> nil
      receipt -> receipt
    end
  end
end
