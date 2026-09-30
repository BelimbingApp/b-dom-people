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
            paid boolean NOT NULL, status varchar(16) NOT NULL,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_types_company_code_unique UNIQUE (company_id, code)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE people_leave_policies (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
            leave_type_id bigint NOT NULL REFERENCES people_leave_types(id),
            version integer NOT NULL, effective_from date NOT NULL, effective_to date,
            entitlement numeric(8,2) NOT NULL, actor_user_id bigint,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_leave_policies_type_version_unique UNIQUE (leave_type_id, version),
            CONSTRAINT people_leave_policies_type_from_unique UNIQUE (leave_type_id, effective_from),
            CONSTRAINT people_leave_policies_effective_range
              CHECK (effective_to IS NULL OR effective_to >= effective_from),
            CONSTRAINT people_leave_policies_entitlement_non_negative CHECK (entitlement >= 0)
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
          """
        ] do
      SQL.query!(Repo, statement, [])
    end
  end
end
