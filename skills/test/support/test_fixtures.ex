defmodule Bilimbi.People.Skills.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  @migrations [
    Path.expand(
      "../../priv/repo/migrations/20260930181101_create_people_skills_catalog.exs",
      __DIR__
    ),
    Path.expand(
      "../../priv/repo/migrations/20260930220137_add_people_skill_assessments.exs",
      __DIR__
    )
  ]

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
      {"people_skill_profile_children_guard", "INSERT OR UPDATE OR DELETE"},
    "people_skill_assessments" =>
      {"people_skill_assessments_guard", "INSERT OR UPDATE OR DELETE"},
    "people_skill_assessment_decisions" => {"people_skill_append_only", "UPDATE OR DELETE"},
    "people_skill_scores" => {"people_skill_scores_guard", "INSERT OR UPDATE OR DELETE"},
    "people_skill_reassessment_requests" =>
      {"people_skill_reassessment_requests_guard", "UPDATE OR DELETE"},
    "people_skill_actions" => {"people_skill_actions_guard", "UPDATE OR DELETE"},
    "people_skill_action_events" => {"people_skill_append_only", "UPDATE OR DELETE"},
    "people_skill_reminders" => {"people_skill_reminders_guard", "UPDATE OR DELETE"}
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
      """,
      """
      CREATE TEMPORARY TABLE people_skill_assessments (#{@common},
        employee_id bigint NOT NULL,
        skill_id bigint NOT NULL REFERENCES people_skills(id),
        profile_id bigint NOT NULL REFERENCES people_skill_profiles(id),
        scale_id bigint NOT NULL REFERENCES people_skill_scales(id),
        required_level integer NOT NULL, criticality varchar(16) NOT NULL,
        weight_percent numeric(5,2) NOT NULL, mandatory boolean NOT NULL,
        assessed_level integer NOT NULL, gap integer NOT NULL,
        priority_multiplier integer NOT NULL, priority_score integer NOT NULL,
        result_band varchar(16) NOT NULL, method varchar(80), evidence varchar(4000) NOT NULL,
        notes varchar(2000), assessed_on date NOT NULL, valid_until date, next_due_on date NOT NULL,
        status varchar(16) NOT NULL, assessor_user_id bigint NOT NULL,
        reviewed_by_user_id bigint, reviewed_at timestamp(0), review_note varchar(2000),
        finalized_by_user_id bigint, finalized_at timestamp(0),
        supersedes_assessment_id bigint REFERENCES people_skill_assessments(id),
        request_key varchar(80) NOT NULL, #{@stamps},
        CONSTRAINT people_skill_assessments_subject_unique
          UNIQUE (id, company_id, employee_id, skill_id),
        CONSTRAINT people_skill_assessments_request_key_unique
          UNIQUE (company_id, assessor_user_id, request_key),
        CONSTRAINT people_skill_assessments_status
          CHECK (status IN ('pending_review', 'verified', 'returned', 'finalized')),
        CONSTRAINT people_skill_assessments_criticality
          CHECK (criticality IN ('critical', 'essential', 'development')),
        CONSTRAINT people_skill_assessments_band
          CHECK (result_band IN ('exceeds', 'meets', 'minor_gap', 'major_gap', 'critical_gap')),
        CONSTRAINT people_skill_assessments_levels
          CHECK (required_level BETWEEN 0 AND 20 AND assessed_level BETWEEN 0 AND 20
            AND gap = GREATEST(required_level - assessed_level, 0)
            AND priority_multiplier >= 0 AND priority_score = gap * priority_multiplier),
        CONSTRAINT people_skill_assessments_evidence CHECK (length(btrim(evidence)) > 0),
        CONSTRAINT people_skill_assessments_dates
          CHECK (valid_until IS NULL OR valid_until >= assessed_on),
        CONSTRAINT people_skill_assessments_workflow CHECK (
          (status = 'pending_review' AND reviewed_at IS NULL AND finalized_at IS NULL) OR
          (status = 'verified' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL
            AND finalized_at IS NULL) OR
          (status = 'returned' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL
            AND review_note IS NOT NULL AND finalized_at IS NULL) OR
          (status = 'finalized' AND reviewed_at IS NOT NULL AND reviewed_by_user_id IS NOT NULL
            AND finalized_at IS NOT NULL AND finalized_by_user_id IS NOT NULL)),
        CONSTRAINT people_skill_assessments_independent CHECK (
          (reviewed_by_user_id IS NULL OR reviewed_by_user_id <> assessor_user_id) AND
          (finalized_by_user_id IS NULL OR finalized_by_user_id <> assessor_user_id))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_assessment_decisions (#{@common},
        assessment_id bigint NOT NULL REFERENCES people_skill_assessments(id),
        decision varchar(16) NOT NULL
          CHECK (decision IN ('submitted', 'verified', 'returned', 'finalized')),
        actor_user_id bigint NOT NULL, note varchar(2000), inserted_at timestamp(0) NOT NULL,
        CONSTRAINT people_skill_assessment_decisions_once UNIQUE (assessment_id, decision)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_scores (#{@common},
        employee_id bigint NOT NULL, skill_id bigint NOT NULL, assessment_id bigint NOT NULL,
        profile_id bigint NOT NULL, required_level integer NOT NULL, current_level integer NOT NULL,
        gap integer NOT NULL, criticality varchar(16) NOT NULL, mandatory boolean NOT NULL,
        priority_score integer NOT NULL, assessed_on date NOT NULL, valid_until date,
        next_due_on date NOT NULL, #{@stamps},
        CONSTRAINT people_skill_scores_assessment_fkey
          FOREIGN KEY (assessment_id, company_id, employee_id, skill_id)
          REFERENCES people_skill_assessments (id, company_id, employee_id, skill_id),
        CONSTRAINT people_skill_scores_subject_unique UNIQUE (company_id, employee_id, skill_id),
        CONSTRAINT people_skill_scores_gap CHECK (gap = GREATEST(required_level - current_level, 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_reassessment_requests (#{@common},
        employee_id bigint NOT NULL,
        skill_id bigint NOT NULL REFERENCES people_skills(id),
        reason varchar(1000) NOT NULL, requested_by_user_id bigint NOT NULL, due_on date NOT NULL,
        status varchar(12) NOT NULL, performed_by_user_id bigint, performed_at timestamp(0),
        assessment_id bigint REFERENCES people_skill_assessments(id),
        cancelled_by_user_id bigint, cancelled_at timestamp(0), #{@stamps},
        CONSTRAINT people_skill_reassessment_requests_state CHECK (
          (status = 'pending' AND performed_at IS NULL AND cancelled_at IS NULL) OR
          (status = 'performed' AND performed_at IS NOT NULL AND performed_by_user_id IS NOT NULL
            AND assessment_id IS NOT NULL AND cancelled_at IS NULL) OR
          (status = 'cancelled' AND cancelled_at IS NOT NULL AND cancelled_by_user_id IS NOT NULL
            AND performed_at IS NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_action_types (#{@common},
        code varchar(80) NOT NULL, name varchar(160) NOT NULL,
        requires_provider boolean NOT NULL, active boolean NOT NULL, #{@stamps},
        CONSTRAINT people_skill_action_types_company_code_unique UNIQUE (company_id, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_actions (#{@common},
        employee_id bigint NOT NULL, employee_name varchar(200) NOT NULL,
        skill_id bigint NOT NULL REFERENCES people_skills(id),
        source_assessment_id bigint REFERENCES people_skill_assessments(id),
        action_type_id bigint NOT NULL REFERENCES people_skill_action_types(id),
        starting_level integer NOT NULL, target_level integer NOT NULL,
        gap_at_start integer NOT NULL,
        criticality varchar(16) NOT NULL, mandatory boolean NOT NULL,
        priority_multiplier integer NOT NULL, priority_score integer NOT NULL,
        priority_explanation varchar(300) NOT NULL, manual_reason varchar(1000),
        objective varchar(2000) NOT NULL, intervention varchar(2000) NOT NULL,
        expected_evidence varchar(2000) NOT NULL, owner_employee_id bigint NOT NULL,
        coordinator_employee_id bigint NOT NULL, provider_employee_id bigint,
        provider_name varchar(160), start_on date NOT NULL, due_on date NOT NULL,
        status varchar(24) NOT NULL, closure varchar(24) NOT NULL,
        approved_by_user_id bigint, approved_at timestamp(0), completed_at timestamp(0),
        completion_evidence varchar(2000), reassessment_due_on date,
        post_assessment_id bigint REFERENCES people_skill_assessments(id),
        post_level integer, improvement integer, next_steps varchar(2000),
        created_by_user_id bigint NOT NULL, request_key varchar(80) NOT NULL, #{@stamps},
        CONSTRAINT people_skill_actions_request_key_unique UNIQUE (company_id, request_key),
        CONSTRAINT people_skill_actions_status CHECK (status IN ('proposed', 'scheduled',
          'not_started', 'in_progress', 'on_hold', 'pending_reassessment', 'completed',
          'cancelled')),
        CONSTRAINT people_skill_actions_closure CHECK (closure IN ('open',
          'pending_reassessment', 'closed_competent', 'further_action_required', 'cancelled')),
        CONSTRAINT people_skill_actions_criticality
          CHECK (criticality IN ('critical', 'essential', 'development')),
        CONSTRAINT people_skill_actions_levels CHECK (
          starting_level BETWEEN 0 AND 20 AND target_level BETWEEN 0 AND 20
          AND gap_at_start = GREATEST(target_level - starting_level, 0)
          AND priority_multiplier >= 0 AND priority_score = gap_at_start * priority_multiplier),
        CONSTRAINT people_skill_actions_dates CHECK (due_on >= start_on),
        CONSTRAINT people_skill_actions_basis
          CHECK (source_assessment_id IS NOT NULL OR manual_reason IS NOT NULL),
        CONSTRAINT people_skill_actions_terminal CHECK (
          (status = 'completed' AND closure IN ('closed_competent', 'further_action_required')
            AND post_assessment_id IS NOT NULL) OR
          (status = 'cancelled' AND closure = 'cancelled') OR
          (status = 'pending_reassessment' AND closure = 'pending_reassessment'
            AND completed_at IS NOT NULL) OR
          (status NOT IN ('completed', 'cancelled', 'pending_reassessment')
            AND closure = 'open'))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_action_events (#{@common},
        action_id bigint NOT NULL REFERENCES people_skill_actions(id),
        event_type varchar(32) NOT NULL, from_status varchar(24), to_status varchar(24),
        comment varchar(2000), evidence varchar(2000), actor_user_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE people_skill_reminders (#{@common},
        rule varchar(24) NOT NULL CHECK (rule IN ('overdue_reassessment', 'expiring_certificate',
          'overdue_action', 'coverage_gap')),
        employee_id bigint,
        skill_id bigint NOT NULL REFERENCES people_skills(id),
        action_id bigint REFERENCES people_skill_actions(id),
        period_key varchar(12) NOT NULL, recipient_user_id bigint NOT NULL, due_on date NOT NULL,
        state varchar(12) NOT NULL CHECK (state IN ('pending', 'sent', 'failed')),
        failure varchar(300), sent_at timestamp(0), #{@stamps},
        CONSTRAINT people_skill_reminders_sent CHECK (state <> 'sent' OR sent_at IS NOT NULL),
        CONSTRAINT people_skill_reminders_once UNIQUE NULLS NOT DISTINCT
          (company_id, rule, employee_id, skill_id, action_id, period_key, recipient_user_id)
      ) ON COMMIT PRESERVE ROWS
      """
    ]

    partial_indexes = [
      "CREATE UNIQUE INDEX people_skill_assessments_one_successor " <>
        "ON people_skill_assessments (supersedes_assessment_id) " <>
        "WHERE supersedes_assessment_id IS NOT NULL",
      "CREATE UNIQUE INDEX people_skill_reassessment_requests_one_open " <>
        "ON people_skill_reassessment_requests (company_id, employee_id, skill_id) " <>
        "WHERE status = 'pending'",
      "CREATE UNIQUE INDEX people_skill_actions_one_per_assessment " <>
        "ON people_skill_actions (source_assessment_id) WHERE source_assessment_id IS NOT NULL"
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

    for statement <- tables ++ lifecycle ++ partial_indexes ++ guard_functions() ++ triggers,
        do: SQL.query!(Repo, statement, [])

    :ok
  end

  # The guard bodies come from the migrations so the tests exercise the real rules.
  defp guard_functions do
    Enum.flat_map(@migrations, fn migration ->
      ~r/execute\("""\n\s*(CREATE FUNCTION .*?\$\$)\n\s*"""\)/s
      |> Regex.scan(File.read!(migration), capture: :all_but_first)
      |> Enum.map(fn [sql] ->
        String.replace(sql, "CREATE FUNCTION ", "CREATE FUNCTION pg_temp.")
      end)
    end)
  end
end
