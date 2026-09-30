defmodule Bilimbi.People.Progression.Fixtures do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.Performance.WorkflowFixtures, as: PerformanceFixtures

  def seed!(opts \\ []) do
    if opts[:web], do: Bilimbi.Base.ModuleRegistry.ContributionRegistry.install!()
    ctx = PerformanceFixtures.seed!(opts)

    unless opts[:web] do
      registry = Bilimbi.Base.ModuleRegistry.ContributionRegistry

      authz =
        Bilimbi.Base.Authz.ContributionValidator.validate_contributions!(
          Enum.map(
            [
              {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
              {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
              {"people/skills", :bilimbi_people_skills, Bilimbi.People.Skills.Contributions},
              {"people/performance", :bilimbi_people_performance,
               Bilimbi.People.Performance.Contributions},
              {"people/progression", :bilimbi_people_progression,
               Bilimbi.People.Progression.Contributions}
            ],
            fn {id, app, module} ->
              %{descriptor: %{id: id, otp_app: app}, payload: module.contributions().authz}
            end
          ) ++
            [
              %{
                descriptor: %{id: "base/tiling", otp_app: :bilimbi_base_tiling},
                payload: %{domains: %{}, verbs: ["publish"], capabilities: [], roles: %{}}
              }
            ]
        )

      snapshot = registry.snapshot!()

      registry.put_snapshot_for_test!(%{
        snapshot
        | consumers: Map.put(snapshot.consumers, :authz, authz)
      })
    end

    for role <- [:manager, :reviewer, :other],
        do:
          PerformanceFixtures.grant!(
            ctx.scope,
            role,
            if(role == :other, do: 74, else: 73),
            ~w(people.progression.policy.manage people.progression.policy.view)
          )

    PerformanceFixtures.grant!(ctx.scope, :viewer, 73, ["people.progression.policy.view"])

    for role <- [:employee, :peer],
        do:
          PerformanceFixtures.grant!(
            ctx.scope,
            role,
            73,
            ~w(people.progression.self.view people.skills.self.view)
          )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_progression_policy_versions (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code text NOT NULL, version integer NOT NULL, name text NOT NULL, effective_from date NOT NULL,
        rules jsonb NOT NULL, status text NOT NULL, actor_user_id bigint NOT NULL,
        published_by_user_id bigint, published_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_progression_policy_content CHECK (version > 0 AND length(btrim(code)) > 0 AND length(btrim(name)) > 0 AND jsonb_typeof(rules) = 'object'),
        CONSTRAINT people_progression_policy_workflow CHECK ((status = 'draft' AND published_at IS NULL AND published_by_user_id IS NULL) OR (status = 'published' AND published_at IS NOT NULL AND published_by_user_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX people_progression_policy_identity ON people_progression_policy_versions(company_id,code,version)",
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE INDEX people_progression_policy_scope ON people_progression_policy_versions(tenant_id,company_id)",
      []
    )

    sql =
      Bilimbi.People.Progression.Migrations.CreateProgression.guard_sql()
      |> String.replace(
        "people_progression_policy_guard",
        "pg_temp.people_progression_policy_guard"
      )

    [function | triggers] = String.split(sql, "CREATE TRIGGER")
    Ecto.Adapters.SQL.query!(Repo, function, [])
    for trigger <- triggers, do: Ecto.Adapters.SQL.query!(Repo, "CREATE TRIGGER" <> trigger, [])
    ctx
  end

  def attrs(ctx, extra \\ %{}) do
    {:ok, profile} = Bilimbi.People.Skills.get_profile(ctx.scope, 73, ctx.profile.id)
    item = hd(profile.items)

    Map.merge(
      %{
        code: "policy-one",
        version: 1,
        name: "Progression policy",
        effective_from: Date.utc_today(),
        rules: %{
          "competence" => [
            %{
              "code" => "criterion-one",
              "skill_id" => item.skill_id,
              "profile_id" => profile.id,
              "profile_version" => profile.version,
              "required_level" => item.required_level
            }
          ],
          "performance" => nil
        }
      },
      extra
    )
  end

  def actor(ctx, role, company \\ 73), do: PerformanceFixtures.actor(ctx, role, company)

  def performance_rules(missing \\ "unknown"),
    do: %{
      "competence" => [],
      "performance" => %{
        "periods" => [%{"start" => "2026-01-01", "end" => "2026-12-31"}],
        "accepted_outcomes" => ["Agreed outcome"],
        "missing_evidence" => missing
      }
    }
end
