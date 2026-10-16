defmodule Bilimbi.People.Workforce.TestFixtures do
  @moduledoc false
  # Workforce reads resolve employment facts from People's own table, so any
  # test that reads employees through the workforce seam creates it first.

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_workforce_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_workforce_employments (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        legacy_employee_id bigint NOT NULL UNIQUE, person_id bigint NOT NULL,
        affiliation_id bigint NOT NULL UNIQUE, employee_number varchar(255) NOT NULL,
        employment_type varchar(255) NOT NULL, status varchar(255) NOT NULL,
        employment_start date, employment_end date, metadata jsonb,
        legacy_created_at timestamp(0), claimed_at timestamp(0) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    :ok
  end
end
