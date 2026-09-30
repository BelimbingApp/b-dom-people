defmodule Bilimbi.People.Claims.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Mirrors migrations 20260930150101 and 20260930170101, including the constraints the facade
  # relies on.
  def create_claim_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_categories (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(60) NOT NULL, name varchar(120) NOT NULL,
        active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_categories_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_types (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        category_id bigint NOT NULL REFERENCES people_claim_categories (id),
        code varchar(60) NOT NULL, name varchar(120) NOT NULL,
        receipt_requirement varchar(20) NOT NULL
          CHECK (receipt_requirement IN ('always', 'above_threshold', 'never')),
        eligibility varchar(20) NOT NULL DEFAULT 'all_employees'
          CHECK (eligibility IN ('all_employees', 'assigned_only')),
        active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_types_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_policies (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        claim_type_id bigint NOT NULL REFERENCES people_claim_types (id),
        effective_from date NOT NULL, effective_to date,
        currency varchar(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
        per_claim_limit numeric(14, 2), monthly_limit numeric(14, 2),
        yearly_limit numeric(14, 2), receipt_threshold numeric(14, 2),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    create_assignment_and_batch_tables!()

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_requests (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL,
        claim_type_id bigint NOT NULL REFERENCES people_claim_types (id),
        claim_policy_id bigint NOT NULL REFERENCES people_claim_policies (id),
        incurred_on date NOT NULL, amount numeric(14, 2) NOT NULL CHECK (amount > 0),
        currency varchar(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
        description varchar(500), receipt_number varchar(100),
        status varchar(20) NOT NULL
          CHECK (status IN ('submitted', 'approved', 'rejected', 'reimbursed', 'withdrawn')),
        duplicate_confirmed boolean NOT NULL DEFAULT false,
        submitted_by_actor_id bigint NOT NULL, submitted_at timestamp(0) NOT NULL,
        withdrawn_by_actor_id bigint, withdrawn_at timestamp(0),
        approved_amount numeric(14, 2), decided_by_actor_id bigint,
        decided_at timestamp(0), decision_reason varchar(500),
        reimbursed_by_actor_id bigint, reimbursed_at timestamp(0),
        payment_reference varchar(100),
        handoff_batch_id bigint REFERENCES people_claim_handoff_batches (id),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_requests_decision_check CHECK (
          (status IN ('submitted', 'withdrawn') AND approved_amount IS NULL
            AND decided_by_actor_id IS NULL AND decided_at IS NULL) OR
          (status IN ('approved', 'reimbursed') AND approved_amount > 0
            AND approved_amount <= amount AND decided_by_actor_id IS NOT NULL
            AND decided_at IS NOT NULL) OR
          (status = 'rejected' AND approved_amount IS NULL
            AND decided_by_actor_id IS NOT NULL AND decided_at IS NOT NULL
            AND decision_reason IS NOT NULL)),
        CONSTRAINT people_claim_requests_reimbursement_check CHECK (
          (status = 'reimbursed' AND reimbursed_by_actor_id IS NOT NULL
            AND reimbursed_at IS NOT NULL) OR
          (status <> 'reimbursed' AND reimbursed_by_actor_id IS NULL
            AND reimbursed_at IS NULL AND payment_reference IS NULL)),
        CONSTRAINT people_claim_requests_handoff_check CHECK (
          handoff_batch_id IS NULL OR status IN ('approved', 'reimbursed'))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX people_claim_requests_receipt_unique
        ON people_claim_requests (company_id, employee_id, receipt_number)
        WHERE receipt_number IS NOT NULL AND status NOT IN ('withdrawn', 'rejected')
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_request_events (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        request_id bigint NOT NULL REFERENCES people_claim_requests (id),
        from_status varchar(20), to_status varchar(20) NOT NULL,
        actor_id bigint NOT NULL, reason varchar(500), occurred_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end

  defp create_assignment_and_batch_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_assignments (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(60) NOT NULL, name varchar(120) NOT NULL,
        effective_from date NOT NULL, effective_to date,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_assignments_company_code_unique UNIQUE (company_id, code),
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_assignment_types (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        assignment_id bigint NOT NULL REFERENCES people_claim_assignments (id),
        claim_type_id bigint NOT NULL REFERENCES people_claim_types (id),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_assignment_types_unique UNIQUE (assignment_id, claim_type_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_assignment_employees (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        assignment_id bigint NOT NULL REFERENCES people_claim_assignments (id),
        employee_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_claim_assignment_employees_unique UNIQUE (assignment_id, employee_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_claim_handoff_batches (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        currency varchar(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
        request_count integer NOT NULL, total_amount numeric(14, 2) NOT NULL,
        created_by_actor_id bigint NOT NULL, created_at timestamp(0) NOT NULL,
        CHECK (request_count > 0 AND total_amount > 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
