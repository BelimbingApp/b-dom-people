defmodule Bilimbi.People.Skills.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  @migration Path.expand(
               "../../priv/repo/migrations/20260930181101_create_people_skills_catalog.exs",
               __DIR__
             )

  @status "status varchar(16) NOT NULL CHECK (status IN ('draft', 'published', 'retired'))"
  @common "id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL"
  @stamps "inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL"

  @guarded %{
    "people_skills" => {"people_skills_guard", "UPDATE"},
    "people_skill_scales" => {"people_skill_scales_guard", "UPDATE OR DELETE"},
    "people_skill_scale_levels" =>
      {"people_skill_scale_levels_guard", "INSERT OR UPDATE OR DELETE"},
    "people_skill_profiles" => {"people_skill_profiles_guard", "UPDATE OR DELETE"},
    "people_skill_profile_items" =>
      {"people_skill_profile_children_guard", "INSERT OR UPDATE OR DELETE"},
    "people_skill_profile_selectors" =>
      {"people_skill_profile_children_guard", "INSERT OR UPDATE OR DELETE"}
  }

  @doc "Temporary copies of the skills tables with the migration's own guard functions."
  def create_skill_tables! do
    tables = [
      """
      CREATE TEMPORARY TABLE people_skill_categories (#{@common},
        code varchar(80) NOT NULL, name varchar(160) NOT NULL, description varchar(2000),
        active boolean NOT NULL, #{@stamps},
        CONSTRAINT people_skill_categories_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skills (#{@common},
        category_id bigint NOT NULL REFERENCES people_skill_categories(id),
        code varchar(80) NOT NULL, name varchar(160) NOT NULL, definition varchar(2000) NOT NULL,
        evidence_guide varchar(2000), critical boolean NOT NULL,
        reassessment_months integer CHECK (reassessment_months BETWEEN 1 AND 120),
        active boolean NOT NULL, #{@stamps},
        CONSTRAINT people_skills_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_scales (#{@common},
        code varchar(80) NOT NULL, name varchar(160) NOT NULL, version integer NOT NULL, #{@status},
        published_at timestamp(0), retired_at timestamp(0), actor_user_id bigint, #{@stamps},
        CONSTRAINT people_skill_scales_code_version_unique UNIQUE (company_id, code, version)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_scale_levels (#{@common},
        scale_id bigint NOT NULL REFERENCES people_skill_scales(id),
        level integer NOT NULL CHECK (level BETWEEN 0 AND 20), name varchar(100) NOT NULL,
        anchor varchar(2000) NOT NULL, authority varchar(2000) NOT NULL, #{@stamps},
        CONSTRAINT people_skill_scale_levels_scale_level_unique UNIQUE (scale_id, level)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_profiles (#{@common},
        code varchar(80) NOT NULL, name varchar(160) NOT NULL, version integer NOT NULL, #{@status},
        scale_id bigint NOT NULL REFERENCES people_skill_scales(id),
        effective_from date, effective_to date,
        published_at timestamp(0), retired_at timestamp(0), actor_user_id bigint, #{@stamps},
        CONSTRAINT people_skill_profiles_code_version_unique UNIQUE (company_id, code, version),
        CHECK (effective_to IS NULL OR effective_to >= effective_from),
        CHECK (status = 'draft' OR effective_from IS NOT NULL)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_profile_items (#{@common},
        profile_id bigint NOT NULL REFERENCES people_skill_profiles(id),
        skill_id bigint NOT NULL REFERENCES people_skills(id),
        sequence integer NOT NULL, required_level integer NOT NULL,
        criticality varchar(16) NOT NULL
          CHECK (criticality IN ('critical', 'essential', 'development')),
        weight_percent numeric(5,2) NOT NULL CHECK (weight_percent >= 0 AND weight_percent <= 100),
        mandatory boolean NOT NULL, evidence_standard varchar(2000), #{@stamps},
        CONSTRAINT people_skill_profile_items_profile_skill_unique UNIQUE (profile_id, skill_id),
        CONSTRAINT people_skill_profile_items_profile_sequence_unique UNIQUE (profile_id, sequence)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_profile_selectors (#{@common},
        profile_id bigint NOT NULL REFERENCES people_skill_profiles(id),
        selector_type varchar(16) NOT NULL, position_id bigint, #{@stamps},
        CONSTRAINT people_skill_profile_selectors_unique
          UNIQUE NULLS NOT DISTINCT (profile_id, selector_type, position_id),
        CHECK ((selector_type = 'company' AND position_id IS NULL) OR
               (selector_type = 'position' AND position_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """
    ]

    lifecycle =
      for table <- ~w(people_skill_scales people_skill_profiles),
          {suffix, status} <- [{"one_draft", "draft"}, {"one_published", "published"}] do
        "CREATE UNIQUE INDEX #{table}_#{suffix} ON #{table} (company_id, code) " <>
          "WHERE status = '#{status}'"
      end

    triggers =
      for {table, {function, events}} <- @guarded do
        "CREATE TRIGGER #{table}_guard BEFORE #{events} ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.#{function}()"
      end

    for statement <- tables ++ lifecycle ++ guard_functions() ++ triggers,
        do: SQL.query!(Repo, statement, [])

    :ok
  end

  # The guard bodies come from the migration so the tests exercise the real rules.
  defp guard_functions do
    ~r/execute\("""\n\s*(CREATE FUNCTION .*?\$\$)\n\s*"""\)/s
    |> Regex.scan(File.read!(@migration), capture: :all_but_first)
    |> Enum.map(fn [sql] ->
      String.replace(sql, "CREATE FUNCTION ", "CREATE FUNCTION pg_temp.")
    end)
  end
end
