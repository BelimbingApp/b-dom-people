defmodule Bilimbi.People.EmployeeWorkspace.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_workspace_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_employee_work_profiles (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, work_location varchar(200),
        work_arrangement varchar(120), notes text,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        UNIQUE (company_id, employee_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_employee_accesses (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, portal_enabled boolean NOT NULL DEFAULT false,
        reason text, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        UNIQUE (company_id, employee_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_employee_change_requests (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        employee_id bigint NOT NULL, field varchar(80) NOT NULL,
        proposed_value varchar(500) NOT NULL, reason text,
        status varchar(20) NOT NULL DEFAULT 'pending',
        requested_by_actor_id bigint NOT NULL, reviewed_by_actor_id bigint,
        reviewed_at timestamp(0), inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_employee_saved_views (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        actor_id bigint NOT NULL, name varchar(120) NOT NULL,
        search varchar(200), status varchar(40),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        UNIQUE (company_id, actor_id, name)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
