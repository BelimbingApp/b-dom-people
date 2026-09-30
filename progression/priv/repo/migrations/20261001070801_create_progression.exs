defmodule Bilimbi.People.Progression.Migrations.CreateProgression do
  use Ecto.Migration

  def up do
    create table(:people_progression_policy_versions) do
      add(:tenant_id, :bigint, null: false)
      add(:company_id, :bigint, null: false)
      add(:code, :text, null: false)
      add(:version, :integer, null: false)
      add(:name, :text, null: false)
      add(:effective_from, :date, null: false)
      add(:rules, :map, null: false)
      add(:status, :text, null: false)
      add(:actor_user_id, :bigint, null: false)
      add(:published_by_user_id, :bigint)
      add(:published_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:people_progression_policy_versions, [:company_id, :code, :version],
        name: :people_progression_policy_identity
      )
    )

    create(
      unique_index(:people_progression_policy_versions, [:company_id, :effective_from],
        where: "status = 'published'",
        name: :people_progression_policy_effective
      )
    )

    create(
      index(:people_progression_policy_versions, [:tenant_id, :company_id],
        name: :people_progression_policy_scope
      )
    )

    create(
      constraint(:people_progression_policy_versions, :people_progression_policy_content,
        check:
          "version > 0 AND length(btrim(code)) > 0 AND length(btrim(name)) > 0 AND jsonb_typeof(rules) = 'object'"
      )
    )

    create(
      constraint(:people_progression_policy_versions, :people_progression_policy_workflow,
        check:
          "(status = 'draft' AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL)"
      )
    )

    [function, trigger] = String.split(guard_sql(), "CREATE TRIGGER")
    execute(function)
    execute("CREATE TRIGGER" <> trigger)
  end

  def down do
    drop(table(:people_progression_policy_versions))
    execute("DROP FUNCTION people_progression_policy_guard()")
  end

  def guard_sql do
    """
    CREATE FUNCTION people_progression_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR OLD.status = 'published' OR
         (to_jsonb(NEW) - ARRAY['status','published_at','published_by_user_id','updated_at']) IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['status','published_at','published_by_user_id','updated_at']) OR NEW.status <> 'published' THEN
        RAISE EXCEPTION 'Policy versions are immutable; publish a new version' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER people_progression_policy_immutable BEFORE UPDATE OR DELETE ON people_progression_policy_versions
      FOR EACH ROW EXECUTE FUNCTION people_progression_policy_guard();
    """
  end
end
