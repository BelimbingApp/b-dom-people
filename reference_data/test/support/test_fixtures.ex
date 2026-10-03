defmodule Bilimbi.People.ReferenceData.TestFixtures do
  @moduledoc false

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_reference_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_reference_data_entries (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        kind varchar(80) NOT NULL, code varchar(100) NOT NULL,
        label varchar(200) NOT NULL, active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_reference_data_entries_company_kind_code_unique UNIQUE (company_id, kind, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_reference_data_aliases (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        entry_id bigint NOT NULL, kind varchar(80) NOT NULL, label varchar(200) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_reference_data_aliases_company_kind_label_unique UNIQUE (company_id, kind, label)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_reference_data_calendar_overrides (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        on_date date NOT NULL, label varchar(200) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_reference_data_calendar_overrides_date_label_unique UNIQUE (company_id, on_date, label)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
