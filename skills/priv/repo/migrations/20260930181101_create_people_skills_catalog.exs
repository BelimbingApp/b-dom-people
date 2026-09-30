defmodule Bilimbi.People.Skills.Migrations.CreateCatalog do
  use Ecto.Migration

  def up do
    create table(:people_skill_categories, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 80, null: false)
      add(:name, :string, size: 160, null: false)
      add(:description, :string, size: 2000)
      add(:active, :boolean, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_categories, [:company_id, :code],
        name: :people_skill_categories_company_code_unique
      )
    )

    create(index(:people_skill_categories, [:tenant_id, :company_id]))

    create table(:people_skills, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:category_id, references(:people_skill_categories, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:code, :string, size: 80, null: false)
      add(:name, :string, size: 160, null: false)
      add(:definition, :string, size: 2000, null: false)
      add(:evidence_guide, :string, size: 2000)
      add(:critical, :boolean, null: false)
      add(:reassessment_months, :integer)
      add(:active, :boolean, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skills, [:company_id, :code], name: :people_skills_company_code_unique)
    )

    create(index(:people_skills, [:tenant_id, :company_id, :category_id]))

    create(
      constraint(:people_skills, :people_skills_reassessment_months_range,
        check: "reassessment_months IS NULL OR reassessment_months BETWEEN 1 AND 120"
      )
    )

    create table(:people_skill_scales, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 80, null: false)
      add(:name, :string, size: 160, null: false)
      add(:version, :integer, null: false)
      add(:status, :string, size: 16, null: false)
      add(:published_at, :naive_datetime)
      add(:retired_at, :naive_datetime)
      add(:actor_user_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_scales, [:company_id, :code, :version],
        name: :people_skill_scales_code_version_unique
      )
    )

    lifecycle_indexes(:people_skill_scales)
    create(index(:people_skill_scales, [:tenant_id, :company_id]))

    create table(:people_skill_scale_levels, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:scale_id, references(:people_skill_scales, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:level, :integer, null: false)
      add(:name, :string, size: 100, null: false)
      add(:anchor, :string, size: 2000, null: false)
      add(:authority, :string, size: 2000, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_scale_levels, [:scale_id, :level],
        name: :people_skill_scale_levels_scale_level_unique
      )
    )

    create(
      constraint(:people_skill_scale_levels, :people_skill_scale_levels_level_range,
        check: "level BETWEEN 0 AND 20"
      )
    )

    create table(:people_skill_profiles, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :string, size: 80, null: false)
      add(:name, :string, size: 160, null: false)
      add(:version, :integer, null: false)
      add(:status, :string, size: 16, null: false)

      add(:scale_id, references(:people_skill_scales, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:effective_from, :date)
      add(:effective_to, :date)
      add(:published_at, :naive_datetime)
      add(:retired_at, :naive_datetime)
      add(:actor_user_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_profiles, [:company_id, :code, :version],
        name: :people_skill_profiles_code_version_unique
      )
    )

    lifecycle_indexes(:people_skill_profiles)
    create(index(:people_skill_profiles, [:tenant_id, :company_id]))

    create(
      constraint(:people_skill_profiles, :people_skill_profiles_effective_range,
        check: "effective_to IS NULL OR effective_to >= effective_from"
      )
    )

    create(
      constraint(:people_skill_profiles, :people_skill_profiles_published_dated,
        check: "status = 'draft' OR effective_from IS NOT NULL"
      )
    )

    create table(:people_skill_profile_items, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:profile_id, references(:people_skill_profiles, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:skill_id, references(:people_skills, type: :bigint, on_delete: :restrict), null: false)
      add(:sequence, :integer, null: false)
      add(:required_level, :integer, null: false)
      add(:criticality, :string, size: 16, null: false)
      add(:weight_percent, :decimal, precision: 5, scale: 2, null: false)
      add(:mandatory, :boolean, null: false)
      add(:evidence_standard, :string, size: 2000)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_profile_items, [:profile_id, :skill_id],
        name: :people_skill_profile_items_profile_skill_unique
      )
    )

    create(
      unique_index(:people_skill_profile_items, [:profile_id, :sequence],
        name: :people_skill_profile_items_profile_sequence_unique
      )
    )

    create(
      constraint(:people_skill_profile_items, :people_skill_profile_items_criticality,
        check: "criticality IN ('critical', 'essential', 'development')"
      )
    )

    create(
      constraint(:people_skill_profile_items, :people_skill_profile_items_weight_range,
        check: "weight_percent >= 0 AND weight_percent <= 100"
      )
    )

    create table(:people_skill_profile_selectors, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)

      add(:profile_id, references(:people_skill_profiles, type: :bigint, on_delete: :restrict),
        null: false
      )

      add(:selector_type, :string, size: 16, null: false)
      add(:position_id, :bigint)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_skill_profile_selectors, [:profile_id, :selector_type, :position_id],
        name: :people_skill_profile_selectors_unique,
        nulls_distinct: false
      )
    )

    create(
      constraint(:people_skill_profile_selectors, :people_skill_profile_selectors_target,
        check:
          "(selector_type = 'company' AND position_id IS NULL) OR " <>
            "(selector_type = 'position' AND position_id IS NOT NULL)"
      )
    )

    guards()
  end

  def down do
    for table <-
          ~w(people_skill_profile_selectors people_skill_profile_items people_skill_profiles
             people_skill_scale_levels people_skill_scales people_skills),
        do: execute("DROP TRIGGER #{table}_guard ON #{table}")

    for function <-
          ~w(people_skill_profile_children_guard people_skill_profiles_guard
             people_skill_scale_levels_guard people_skill_scales_guard people_skills_guard),
        do: execute("DROP FUNCTION #{function}()")

    drop(table(:people_skill_profile_selectors))
    drop(table(:people_skill_profile_items))
    drop(table(:people_skill_profiles))
    drop(table(:people_skill_scale_levels))
    drop(table(:people_skill_scales))
    drop(table(:people_skills))
    drop(table(:people_skill_categories))
  end

  # At most one open draft and one published version per company and code.
  defp lifecycle_indexes(table) do
    create(
      constraint(table, :"#{table}_status", check: "status IN ('draft', 'published', 'retired')")
    )

    create(
      unique_index(table, [:company_id, :code],
        name: :"#{table}_one_draft",
        where: "status = 'draft'"
      )
    )

    create(
      unique_index(table, [:company_id, :code],
        name: :"#{table}_one_published",
        where: "status = 'published'"
      )
    )
  end

  # The database refuses what the facade never does: a changed skill code or
  # owner, and any edit to a published or retired scale or profile, or to its
  # levels, items or selectors. The only permitted change after draft is
  # published to retired.
  defp guards do
    execute("""
    CREATE FUNCTION people_skills_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.code <> OLD.code OR NEW.company_id <> OLD.company_id
         OR NEW.tenant_id <> OLD.tenant_id THEN
        RAISE EXCEPTION 'skill % code and company are stable', OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skills_guard BEFORE UPDATE ON people_skills
    FOR EACH ROW EXECUTE FUNCTION people_skills_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_scales_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.status = 'draft' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        IF NEW.code <> OLD.code OR NEW.version <> OLD.version
           OR NEW.company_id <> OLD.company_id OR NEW.tenant_id <> OLD.tenant_id THEN
          RAISE EXCEPTION 'skill scale % identity is stable', OLD.id;
        END IF;
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status = 'retired'
         AND NEW.code = OLD.code AND NEW.name = OLD.name AND NEW.version = OLD.version
         AND NEW.company_id = OLD.company_id AND NEW.tenant_id = OLD.tenant_id
         AND NEW.published_at IS NOT DISTINCT FROM OLD.published_at THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'skill scale % is % and immutable', OLD.id, OLD.status;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_scales_guard BEFORE UPDATE OR DELETE ON people_skill_scales
    FOR EACH ROW EXECUTE FUNCTION people_skill_scales_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_scale_levels_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      parent_status text;
    BEGIN
      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT status INTO parent_status FROM people_skill_scales WHERE id = OLD.scale_id;
        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'skill scale % is not draft; its levels are immutable', OLD.scale_id;
        END IF;
      END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT status INTO parent_status FROM people_skill_scales WHERE id = NEW.scale_id;
        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'skill scale % is not draft; its levels are immutable', NEW.scale_id;
        END IF;
        RETURN NEW;
      END IF;
      RETURN OLD;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_scale_levels_guard
    BEFORE INSERT OR UPDATE OR DELETE ON people_skill_scale_levels
    FOR EACH ROW EXECUTE FUNCTION people_skill_scale_levels_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_profiles_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.status = 'draft' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        IF NEW.code <> OLD.code OR NEW.version <> OLD.version
           OR NEW.company_id <> OLD.company_id OR NEW.tenant_id <> OLD.tenant_id THEN
          RAISE EXCEPTION 'skill profile % identity is stable', OLD.id;
        END IF;
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status = 'retired'
         AND NEW.code = OLD.code AND NEW.name = OLD.name AND NEW.version = OLD.version
         AND NEW.company_id = OLD.company_id AND NEW.tenant_id = OLD.tenant_id
         AND NEW.scale_id = OLD.scale_id AND NEW.effective_from = OLD.effective_from
         AND NEW.published_at IS NOT DISTINCT FROM OLD.published_at
         AND NEW.effective_to IS NOT NULL THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'skill profile % is % and immutable', OLD.id, OLD.status;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER people_skill_profiles_guard BEFORE UPDATE OR DELETE ON people_skill_profiles
    FOR EACH ROW EXECUTE FUNCTION people_skill_profiles_guard()
    """)

    execute("""
    CREATE FUNCTION people_skill_profile_children_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      parent_status text;
    BEGIN
      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT status INTO parent_status FROM people_skill_profiles WHERE id = OLD.profile_id;
        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'skill profile % is not draft; its % are immutable',
            OLD.profile_id, TG_TABLE_NAME;
        END IF;
      END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT status INTO parent_status FROM people_skill_profiles WHERE id = NEW.profile_id;
        IF parent_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'skill profile % is not draft; its % are immutable',
            NEW.profile_id, TG_TABLE_NAME;
        END IF;
        RETURN NEW;
      END IF;
      RETURN OLD;
    END;
    $$
    """)

    for table <- ~w(people_skill_profile_items people_skill_profile_selectors) do
      execute("""
      CREATE TRIGGER #{table}_guard BEFORE INSERT OR UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION people_skill_profile_children_guard()
      """)
    end
  end
end
