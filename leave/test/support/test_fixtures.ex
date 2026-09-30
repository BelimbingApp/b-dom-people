defmodule Bilimbi.People.Leave.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_leave_tables! do
    for statement <- [
          """
          CREATE TEMPORARY TABLE people_leave_types (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            code varchar(40) NOT NULL, name varchar(120) NOT NULL, unit varchar(8) NOT NULL,
            paid boolean NOT NULL, balance_required boolean NOT NULL DEFAULT true,
            status varchar(16) NOT NULL,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_types_company_code_unique UNIQUE (company_id, code)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE people_leave_policies (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            leave_type_id bigint NOT NULL REFERENCES people_leave_types(id),
            version integer NOT NULL, effective_from date NOT NULL, effective_to date,
            entitlement numeric(8,2) NOT NULL, carry_forward_cap numeric(8,2),
            actor_user_id bigint,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_policies_type_version_unique UNIQUE (leave_type_id, version),
            CONSTRAINT people_leave_policies_type_from_unique UNIQUE (leave_type_id, effective_from),
            CONSTRAINT people_leave_policies_effective_range
              CHECK (effective_to IS NULL OR effective_to >= effective_from),
            CONSTRAINT people_leave_policies_entitlement_non_negative CHECK (entitlement >= 0),
            CONSTRAINT people_leave_policies_carry_forward_cap_non_negative
              CHECK (carry_forward_cap IS NULL OR carry_forward_cap >= 0)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE people_leave_ledger_entries (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            employee_id bigint NOT NULL,
            leave_type_id bigint NOT NULL REFERENCES people_leave_types(id),
            leave_year integer NOT NULL, entry_type varchar(24) NOT NULL,
            quantity numeric(10,2) NOT NULL, unit varchar(8) NOT NULL,
            policy_id bigint REFERENCES people_leave_policies(id), policy_version integer,
            occurred_on date NOT NULL, source varchar(32) NOT NULL, entry_key varchar(160) NOT NULL,
            actor_user_id bigint, note varchar(500), inserted_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_ledger_entries_source_key_unique
              UNIQUE (company_id, source, entry_key)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE FUNCTION pg_temp.people_leave_ledger_entries_append_only() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'people_leave_ledger_entries is append-only';
          END;
          $$
          """,
          """
          CREATE TRIGGER people_leave_ledger_entries_append_only
          BEFORE UPDATE OR DELETE ON people_leave_ledger_entries
          FOR EACH ROW EXECUTE FUNCTION pg_temp.people_leave_ledger_entries_append_only()
          """,
          """
          CREATE TEMPORARY TABLE people_leave_requests (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            employee_id bigint NOT NULL,
            leave_type_id bigint NOT NULL REFERENCES people_leave_types(id),
            leave_year integer NOT NULL, starts_on date NOT NULL, ends_on date NOT NULL,
            day_part varchar(8) NOT NULL, quantity numeric(10,2) NOT NULL, unit varchar(8) NOT NULL,
            status varchar(16) NOT NULL, reason varchar(500), request_key varchar(160) NOT NULL,
            requested_by_user_id bigint NOT NULL, decided_by_user_id bigint,
            decided_at timestamp(6), decision_note varchar(500), cancelled_by_user_id bigint,
            cancelled_at timestamp(6),
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_requests_employee_key_unique
              UNIQUE (company_id, employee_id, request_key),
            CONSTRAINT people_leave_requests_date_range CHECK (ends_on >= starts_on),
            CONSTRAINT people_leave_requests_quantity_positive CHECK (quantity > 0),
            CONSTRAINT people_leave_requests_status
              CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
            CONSTRAINT people_leave_requests_day_part
              CHECK (day_part IN ('full', 'am', 'pm', 'hours'))
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE people_leave_request_days (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            employee_id bigint NOT NULL,
            request_id bigint NOT NULL REFERENCES people_leave_requests(id),
            on_date date NOT NULL, am boolean NOT NULL, pm boolean NOT NULL,
            quantity numeric(10,2) NOT NULL, active boolean NOT NULL,
            CONSTRAINT people_leave_request_days_request_date_unique UNIQUE (request_id, on_date),
            CONSTRAINT people_leave_request_days_slot CHECK (am OR pm)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE UNIQUE INDEX people_leave_request_days_am_unique
          ON people_leave_request_days (company_id, employee_id, on_date) WHERE active AND am
          """,
          """
          CREATE UNIQUE INDEX people_leave_request_days_pm_unique
          ON people_leave_request_days (company_id, employee_id, on_date) WHERE active AND pm
          """,
          """
          CREATE TEMPORARY TABLE people_leave_request_events (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            request_id bigint NOT NULL REFERENCES people_leave_requests(id),
            from_status varchar(16), to_status varchar(16) NOT NULL,
            actor_user_id bigint NOT NULL, note varchar(500), occurred_at timestamp(6) NOT NULL
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE FUNCTION pg_temp.people_leave_request_events_append_only() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'people_leave_request_events is append-only';
          END;
          $$
          """,
          """
          CREATE TRIGGER people_leave_request_events_append_only
          BEFORE UPDATE OR DELETE ON people_leave_request_events
          FOR EACH ROW EXECUTE FUNCTION pg_temp.people_leave_request_events_append_only()
          """,
          """
          CREATE TEMPORARY TABLE people_leave_carry_forward_skips (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            from_year integer NOT NULL, employee_id bigint NOT NULL,
            employee_label varchar(300) NOT NULL,
            leave_type_id bigint NOT NULL REFERENCES people_leave_types(id),
            reason varchar(24) NOT NULL, blocking_year integer NOT NULL,
            inserted_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_carry_forward_skips_unique
              UNIQUE (company_id, from_year, employee_id, leave_type_id),
            CONSTRAINT people_leave_carry_forward_skips_reason
              CHECK (reason IN ('pending', 'previous_year_open'))
          ) ON COMMIT PRESERVE ROWS
          """
        ] do
      SQL.query!(Repo, statement, [])
    end
  end
end
