defmodule Bilimbi.People.Claims.Migrations.CreatePeopleClaims do
  use Ecto.Migration

  def up do
    create table(:people_claim_categories, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 60, null: false)
      add(:name, :string, size: 120, null: false)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_claim_categories, [:company_id, :code],
        name: :people_claim_categories_company_code_unique
      )
    )

    create(index(:people_claim_categories, [:tenant_id, :company_id]))

    create table(:people_claim_types, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:category_id, references(:people_claim_categories, on_delete: :restrict),
        null: false
      )

      add(:code, :string, size: 60, null: false)
      add(:name, :string, size: 120, null: false)
      add(:receipt_requirement, :string, size: 20, null: false)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_claim_types, [:company_id, :code],
        name: :people_claim_types_company_code_unique
      )
    )

    create(index(:people_claim_types, [:tenant_id, :company_id, :category_id]))

    create(
      constraint(:people_claim_types, :people_claim_types_receipt_requirement_check,
        check: "receipt_requirement IN ('always', 'above_threshold', 'never')"
      )
    )

    create table(:people_claim_policies, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:claim_type_id, references(:people_claim_types, on_delete: :restrict), null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      add(:currency, :string, size: 3, null: false)
      add(:per_claim_limit, :decimal, precision: 14, scale: 2)
      add(:monthly_limit, :decimal, precision: 14, scale: 2)
      add(:yearly_limit, :decimal, precision: 14, scale: 2)
      add(:receipt_threshold, :decimal, precision: 14, scale: 2)
      timestamps(type: :naive_datetime)
    end

    create(
      index(:people_claim_policies, [:tenant_id, :company_id, :claim_type_id, :effective_from],
        name: :people_claim_policies_scope_idx
      )
    )

    create(
      constraint(:people_claim_policies, :people_claim_policies_period_check,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create(
      constraint(:people_claim_policies, :people_claim_policies_currency_check,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:people_claim_policies, :people_claim_policies_amounts_check,
        check:
          "(per_claim_limit IS NULL OR per_claim_limit > 0) AND " <>
            "(monthly_limit IS NULL OR monthly_limit > 0) AND " <>
            "(yearly_limit IS NULL OR yearly_limit > 0) AND " <>
            "(receipt_threshold IS NULL OR receipt_threshold >= 0)"
      )
    )

    create table(:people_claim_requests, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:employee_id, :bigint, null: false)
      add(:claim_type_id, references(:people_claim_types, on_delete: :restrict), null: false)

      add(:claim_policy_id, references(:people_claim_policies, on_delete: :restrict),
        null: false
      )

      add(:incurred_on, :date, null: false)
      add(:amount, :decimal, precision: 14, scale: 2, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:description, :string, size: 500)
      add(:receipt_number, :string, size: 100)
      add(:status, :string, size: 20, null: false)
      add(:duplicate_confirmed, :boolean, null: false, default: false)
      add(:submitted_by_actor_id, :bigint, null: false)
      add(:submitted_at, :naive_datetime, null: false)
      add(:withdrawn_by_actor_id, :bigint)
      add(:withdrawn_at, :naive_datetime)
      timestamps(type: :naive_datetime)
    end

    create(
      index(:people_claim_requests, [:tenant_id, :company_id, :employee_id, :status],
        name: :people_claim_requests_scope_idx
      )
    )

    create(
      index(:people_claim_requests, [:company_id, :employee_id, :claim_type_id, :incurred_on],
        name: :people_claim_requests_usage_idx
      )
    )

    create(
      unique_index(
        :people_claim_requests,
        [:company_id, :employee_id, :receipt_number],
        name: :people_claim_requests_receipt_unique,
        where: "receipt_number IS NOT NULL AND status <> 'withdrawn'"
      )
    )

    create(
      constraint(:people_claim_requests, :people_claim_requests_status_check,
        check: "status IN ('submitted', 'withdrawn')"
      )
    )

    create(
      constraint(:people_claim_requests, :people_claim_requests_amount_check,
        check: "amount > 0"
      )
    )

    create(
      constraint(:people_claim_requests, :people_claim_requests_currency_check,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create table(:people_claim_request_events, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:request_id, references(:people_claim_requests, on_delete: :restrict), null: false)

      add(:from_status, :string, size: 20)
      add(:to_status, :string, size: 20, null: false)
      add(:actor_id, :bigint, null: false)
      add(:occurred_at, :naive_datetime, null: false)
    end

    create(
      index(:people_claim_request_events, [:tenant_id, :company_id, :request_id],
        name: :people_claim_request_events_scope_idx
      )
    )
  end

  def down do
    drop(table(:people_claim_request_events))
    drop(table(:people_claim_requests))
    drop(table(:people_claim_policies))
    drop(table(:people_claim_types))
    drop(table(:people_claim_categories))
  end
end
