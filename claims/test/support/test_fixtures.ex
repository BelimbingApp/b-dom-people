defmodule Bilimbi.People.Claims.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Mirrors migration 20260930150101, including the constraints the facade
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
        status varchar(20) NOT NULL CHECK (status IN ('submitted', 'withdrawn')),
        duplicate_confirmed boolean NOT NULL DEFAULT false,
        submitted_by_actor_id bigint NOT NULL, submitted_at timestamp(0) NOT NULL,
        withdrawn_by_actor_id bigint, withdrawn_at timestamp(0),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX people_claim_requests_receipt_unique
        ON people_claim_requests (company_id, employee_id, claim_type_id, receipt_number)
        WHERE receipt_number IS NOT NULL AND status <> 'withdrawn'
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
        actor_id bigint NOT NULL, occurred_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
