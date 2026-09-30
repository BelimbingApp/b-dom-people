defmodule Bilimbi.People.Organisation.TestFixtures do
  @moduledoc false

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_position_tables! do
    SQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS btree_gist", [])

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_positions (
        id bigserial PRIMARY KEY,
        company_id bigint NOT NULL REFERENCES companies(id),
        code varchar(255) NOT NULL,
        parent_id bigint,
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL,
        CONSTRAINT people_positions_company_id_code_index UNIQUE (company_id, code),
        CONSTRAINT people_positions_id_company_id_index UNIQUE (id, company_id),
        CONSTRAINT people_positions_not_own_parent CHECK (parent_id IS NULL OR parent_id <> id),
        CONSTRAINT people_positions_parent_company_fk
          FOREIGN KEY (parent_id, company_id) REFERENCES people_positions(id, company_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_position_revisions (
        id bigserial PRIMARY KEY,
        position_id bigint NOT NULL REFERENCES people_positions(id),
        version integer NOT NULL,
        title varchar(255) NOT NULL,
        effective_from date NOT NULL,
        effective_to date,
        inserted_at timestamp(6) NOT NULL,
        CONSTRAINT people_position_revisions_position_id_version_index UNIQUE (position_id, version),
        CONSTRAINT people_position_revisions_no_overlap
          EXCLUDE USING gist (position_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&),
        CONSTRAINT people_position_revisions_valid_interval
          CHECK (effective_to IS NULL OR effective_to >= effective_from)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_position_placements (
        id bigserial PRIMARY KEY,
        position_id bigint NOT NULL REFERENCES people_positions(id),
        employee_id bigint NOT NULL REFERENCES employees(id),
        kind varchar(255) NOT NULL,
        effective_from date NOT NULL,
        effective_to date,
        inserted_at timestamp(6) NOT NULL,
        CONSTRAINT people_position_placements_kind CHECK (kind IN ('substantive', 'acting', 'concurrent')),
        CONSTRAINT people_position_placements_valid_interval
          CHECK (effective_to IS NULL OR effective_to >= effective_from),
        CONSTRAINT people_position_placements_one_substantive
          EXCLUDE USING gist (position_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&)
          WHERE (kind = 'substantive')
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
