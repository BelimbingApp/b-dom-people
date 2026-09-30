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
    field(:approved_amount, :decimal)
    field(:decided_by_actor_id, :integer)
    field(:decided_at, :naive_datetime)
    field(:decision_reason, :string)
    field(:reimbursed_by_actor_id, :integer)
    field(:reimbursed_at, :naive_datetime)
    field(:payment_reference, :string)
    field(:handoff_batch_id, :integer)
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

  @doc """
  Records an approval, in full unless `approved_amount` is lower; a lower
  amount needs a reason.
  """
  def approval_changeset(request, attrs, actor_id, now) do
    request
    |> cast(attrs, [:approved_amount, :decision_reason], empty_values: [""])
    |> update_change(:decision_reason, &blank_to_nil/1)
    |> put_new_amount(request.amount)
    |> validate_length(:decision_reason, max: 500)
    |> Money.validate_amount(:approved_amount, min: :positive)
    |> validate_partial_approval(request.amount)
    |> put_change(:status, "approved")
    |> put_change(:decided_by_actor_id, actor_id)
    |> put_change(:decided_at, now)
  end

  def rejection_changeset(request, attrs, actor_id, now) do
    request
    |> cast(attrs, [:decision_reason], empty_values: [""])
    |> update_change(:decision_reason, &blank_to_nil/1)
    |> validate_required([:decision_reason])
    |> validate_length(:decision_reason, max: 500)
    |> put_change(:status, "rejected")
    |> put_change(:decided_by_actor_id, actor_id)
    |> put_change(:decided_at, now)
  end

  def reimbursement_changeset(request, attrs, actor_id, now) do
    request
    |> cast(attrs, [:payment_reference], empty_values: [""])
    |> update_change(:payment_reference, &blank_to_nil/1)
    |> validate_length(:payment_reference, max: 100)
    |> put_change(:status, "reimbursed")
    |> put_change(:reimbursed_by_actor_id, actor_id)
    |> put_change(:reimbursed_at, now)
  end

  defp put_new_amount(changeset, amount) do
    if get_field(changeset, :approved_amount),
      do: changeset,
      else: put_change(changeset, :approved_amount, amount)
  end

  defp validate_partial_approval(changeset, requested) do
    approved = get_field(changeset, :approved_amount)

    cond do
      is_nil(approved) ->
        changeset

      Decimal.gt?(approved, requested) ->
        add_error(changeset, :approved_amount, "must not exceed the claimed amount")

      Decimal.lt?(approved, requested) and is_nil(get_field(changeset, :decision_reason)) ->
        add_error(changeset, :decision_reason, "is required when approving less than claimed")

      true ->
        changeset
    end
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
