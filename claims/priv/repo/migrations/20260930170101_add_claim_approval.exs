defmodule Bilimbi.People.Claims.Migrations.AddClaimApproval do
  use Ecto.Migration

  # Claim assignment, decision, reimbursement, and hand-off. Fresh Bilimbi
  # schema: it extends the unreleased claims tables and copies no source
  # table or migration.
  def up do
    alter table(:people_claim_catalog_types) do
      add(:eligibility, :string, size: 20, null: false, default: "all_employees")
    end

    create(
      constraint(:people_claim_catalog_types, :people_claim_catalog_types_eligibility_check,
        check: "eligibility IN ('all_employees', 'assigned_only')"
      )
    )

    create table(:people_claim_employee_enrolments, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 60, null: false)
      add(:name, :string, size: 120, null: false)
      add(:effective_from, :date, null: false)
      add(:effective_to, :date)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_claim_employee_enrolments, [:company_id, :code],
        name: :people_claim_employee_enrolments_company_code_unique
      )
    )

    create(index(:people_claim_employee_enrolments, [:tenant_id, :company_id]))

    create(
      constraint(
        :people_claim_employee_enrolments,
        :people_claim_employee_enrolments_period_check,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create table(:people_claim_assignment_types, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:assignment_id, references(:people_claim_employee_enrolments, on_delete: :restrict),
        null: false
      )

      add(:claim_type_id, references(:people_claim_catalog_types, on_delete: :restrict),
        null: false
      )

      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_claim_assignment_types, [:assignment_id, :claim_type_id],
        name: :people_claim_assignment_types_unique
      )
    )

    create(
      index(:people_claim_assignment_types, [:tenant_id, :company_id, :claim_type_id],
        name: :people_claim_assignment_types_scope_idx
      )
    )

    create table(:people_claim_assignment_employees, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:assignment_id, references(:people_claim_employee_enrolments, on_delete: :restrict),
        null: false
      )

      add(:employee_id, :bigint, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_claim_assignment_employees, [:assignment_id, :employee_id],
        name: :people_claim_assignment_employees_unique
      )
    )

    create(
      index(:people_claim_assignment_employees, [:tenant_id, :company_id, :employee_id],
        name: :people_claim_assignment_employees_scope_idx
      )
    )

    create table(:people_claim_handoff_batches, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:currency, :string, size: 3, null: false)
      add(:request_count, :integer, null: false)
      add(:total_amount, :decimal, precision: 14, scale: 2, null: false)
      add(:created_by_actor_id, :bigint, null: false)
      add(:created_at, :naive_datetime, null: false)
    end

    create(
      index(:people_claim_handoff_batches, [:tenant_id, :company_id, :created_at],
        name: :people_claim_handoff_batches_scope_idx
      )
    )

    create(
      constraint(:people_claim_handoff_batches, :people_claim_handoff_batches_currency_check,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:people_claim_handoff_batches, :people_claim_handoff_batches_totals_check,
        check: "request_count > 0 AND total_amount > 0"
      )
    )

    alter table(:people_claim_submissions) do
      add(:approved_amount, :decimal, precision: 14, scale: 2)
      add(:decided_by_actor_id, :bigint)
      add(:decided_at, :naive_datetime)
      add(:decision_reason, :string, size: 500)
      add(:reimbursed_by_actor_id, :bigint)
      add(:reimbursed_at, :naive_datetime)
      add(:payment_reference, :string, size: 100)

      add(:handoff_batch_id, references(:people_claim_handoff_batches, on_delete: :restrict))
    end

    create(index(:people_claim_submissions, [:handoff_batch_id]))

    create(
      index(:people_claim_submissions, [:tenant_id, :company_id, :status, :currency],
        name: :people_claim_submissions_queue_idx
      )
    )

    drop(constraint(:people_claim_submissions, :people_claim_submissions_status_check))

    create(
      constraint(:people_claim_submissions, :people_claim_submissions_status_check,
        check: "status IN ('submitted', 'approved', 'rejected', 'reimbursed', 'withdrawn')"
      )
    )

    create(
      constraint(:people_claim_submissions, :people_claim_submissions_decision_check,
        check:
          "(status IN ('submitted', 'withdrawn') AND approved_amount IS NULL " <>
            "AND decided_by_actor_id IS NULL AND decided_at IS NULL) OR " <>
            "(status IN ('approved', 'reimbursed') AND approved_amount > 0 " <>
            "AND approved_amount <= amount AND decided_by_actor_id IS NOT NULL " <>
            "AND decided_at IS NOT NULL) OR " <>
            "(status = 'rejected' AND approved_amount IS NULL " <>
            "AND decided_by_actor_id IS NOT NULL AND decided_at IS NOT NULL " <>
            "AND decision_reason IS NOT NULL)"
      )
    )

    create(
      constraint(:people_claim_submissions, :people_claim_submissions_reimbursement_check,
        check:
          "(status = 'reimbursed' AND reimbursed_by_actor_id IS NOT NULL " <>
            "AND reimbursed_at IS NOT NULL) OR " <>
            "(status <> 'reimbursed' AND reimbursed_by_actor_id IS NULL " <>
            "AND reimbursed_at IS NULL AND payment_reference IS NULL)"
      )
    )

    create(
      constraint(:people_claim_submissions, :people_claim_submissions_handoff_check,
        check: "handoff_batch_id IS NULL OR status IN ('approved', 'reimbursed')"
      )
    )

    drop(index(:people_claim_submissions, [], name: :people_claim_submissions_receipt_unique))

    create(
      unique_index(
        :people_claim_submissions,
        [:company_id, :employee_id, :receipt_number],
        name: :people_claim_submissions_receipt_unique,
        where: "receipt_number IS NOT NULL AND status NOT IN ('withdrawn', 'rejected')"
      )
    )

    alter table(:people_claim_request_events) do
      add(:reason, :string, size: 500)
    end
  end

  def down do
    alter table(:people_claim_request_events) do
      remove(:reason)
    end

    drop(index(:people_claim_submissions, [], name: :people_claim_submissions_receipt_unique))

    create(
      unique_index(
        :people_claim_submissions,
        [:company_id, :employee_id, :receipt_number],
        name: :people_claim_submissions_receipt_unique,
        where: "receipt_number IS NOT NULL AND status <> 'withdrawn'"
      )
    )

    drop(constraint(:people_claim_submissions, :people_claim_submissions_handoff_check))
    drop(constraint(:people_claim_submissions, :people_claim_submissions_reimbursement_check))
    drop(constraint(:people_claim_submissions, :people_claim_submissions_decision_check))
    drop(constraint(:people_claim_submissions, :people_claim_submissions_status_check))

    create(
      constraint(:people_claim_submissions, :people_claim_submissions_status_check,
        check: "status IN ('submitted', 'withdrawn')"
      )
    )

    drop(index(:people_claim_submissions, [], name: :people_claim_submissions_queue_idx))
    drop(index(:people_claim_submissions, [:handoff_batch_id]))

    alter table(:people_claim_submissions) do
      remove(:handoff_batch_id)
      remove(:payment_reference)
      remove(:reimbursed_at)
      remove(:reimbursed_by_actor_id)
      remove(:decision_reason)
      remove(:decided_at)
      remove(:decided_by_actor_id)
      remove(:approved_amount)
    end

    drop(table(:people_claim_handoff_batches))
    drop(table(:people_claim_assignment_employees))
    drop(table(:people_claim_assignment_types))
    drop(table(:people_claim_employee_enrolments))
    drop(constraint(:people_claim_catalog_types, :people_claim_catalog_types_eligibility_check))

    alter table(:people_claim_catalog_types) do
      remove(:eligibility)
    end
  end
end
