defmodule Bilimbi.People.Performance.WorkflowFixtures do
  @moduledoc false
  alias Bilimbi.Base.{Authz, Tenancy}
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.People.{Organisation, Performance, Skills}
  alias Bilimbi.People.Workforce.AuthorizationFixtures

  @users %{manager: 101, reviewer: 102, employee: 103, peer: 104, other: 105, viewer: 106}
  def seed!(opts \\ []) do
    unless opts[:web], do: install_snapshot!()
    UserFixtures.create_user_tables!()

    unless opts[:web] do
      SettingsFixtures.create_settings_table!()
      AuthzFixtures.create_authz_tables!()
    end

    Bilimbi.People.Organisation.TestFixtures.create_position_tables!()
    Bilimbi.People.Skills.TestFixtures.create_skill_tables!()
    Bilimbi.People.Performance.TestFixtures.create_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: false})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    manager = employee!(scope, 73, "M1", nil)
    subject = employee!(scope, 73, "E1", manager.id)
    unrelated = employee!(scope, 73, "E2", nil)
    other = employee!(scope, 74, "E3", nil)
    people = %{manager: manager, employee: subject, peer: unrelated, other: other}

    for {role, id} <- @users do
      company = if role == :other, do: 74, else: 73

      UserFixtures.insert_user!(%{
        id: id,
        company_id: company,
        employee_id: people[role] && people[role].id,
        email: "#{role}@example.test",
        name: "Actor #{role}"
      })
    end

    caps = Performance.Contributions.contributions().authz.capabilities
    for role <- [:manager, :reviewer], do: grant!(scope, role, 73, caps)

    for role <- [:employee, :peer],
        do:
          grant!(
            scope,
            role,
            73,
            ~w(people.performance.self.view people.performance.view people.performance.reviews.submit)
          )

    grant!(scope, :viewer, 73, ["people.performance.view"])
    grant!(scope, :other, 74, caps)

    setup_scope =
      AuthorizationFixtures.sign_in!(scope, 73, @users.manager, ~w(
        people.organisation.manage
        people.skills.catalog.manage
        people.skills.profiles.publish
      ))

    {:ok, position} = Organisation.create_position(setup_scope, 73, %{code: "position-one"})

    {:ok, _} =
      Organisation.record_version(setup_scope, 73, position.id, %{
        version: 1,
        title: "Position one",
        effective_from: ~D[2026-01-01]
      })

    {:ok, _} =
      Organisation.assign(setup_scope, 73, position.id, %{
        employee_id: subject.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    {:ok, category} =
      Skills.create_category(setup_scope, 73, %{code: "category-one", name: "Skill category"})

    {:ok, skill} =
      Skills.create_skill(setup_scope, 73, %{
        category_id: category.id,
        code: "skill-one",
        name: "Skill one",
        definition: "Governed skill definition"
      })

    {:ok, scale} = Skills.create_scale(setup_scope, 73, %{code: "scale-one", name: "Scale one"})

    for level <- 0..1 do
      {:ok, _} =
        Skills.put_scale_level(setup_scope, 73, scale.id, %{
          level: level,
          name: "Level #{level}",
          anchor: "Observed evidence",
          authority: "Company policy"
        })
    end

    {:ok, _} = Skills.publish_scale(setup_scope, 73, scale.id)

    {:ok, profile} =
      Skills.create_profile(setup_scope, 73, %{
        code: "profile-one",
        name: "Profile one",
        scale_id: scale.id
      })

    {:ok, _} =
      Skills.put_item(setup_scope, 73, profile.id, %{
        skill_id: skill.id,
        required_level: 1,
        criticality: "essential",
        weight_percent: "100",
        mandatory: true
      })

    {:ok, _} = Skills.add_selector(setup_scope, 73, profile.id, :company)
    # This fixture publishes Skills through its own capability and public API.
    ctx = %{scope: scope, people: people, position: position, profile: profile}

    {:ok, _} =
      Skills.publish_profile(
        setup_scope,
        73,
        profile.id,
        ~D[2026-01-01]
      )

    ctx
  end

  def install_snapshot! do
    alias Bilimbi.Base.ModuleRegistry.ContributionRegistry

    authz =
      Bilimbi.Base.Authz.ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "base/authz", otp_app: :bilimbi_base_authz},
          payload: Bilimbi.Base.Authz.Contributions.contributions().authz
        },
        %{
          descriptor: %{id: "core/company", otp_app: :bilimbi_core_company},
          payload: Bilimbi.Core.Company.Contributions.contributions().authz
        },
        %{
          descriptor: %{id: "base/tiling", otp_app: :bilimbi_base_tiling},
          payload: %{domains: %{}, verbs: ["publish"], capabilities: [], roles: %{}}
        },
        %{
          descriptor: %{id: "people/organisation", otp_app: :bilimbi_people_organisation},
          payload: Bilimbi.People.Organisation.Contributions.contributions().authz
        },
        %{
          descriptor: %{id: "people/skills", otp_app: :bilimbi_people_skills},
          payload: Bilimbi.People.Skills.Contributions.contributions().authz
        },
        %{
          descriptor: %{id: "people/performance", otp_app: :bilimbi_people_performance},
          payload: Bilimbi.People.Performance.Contributions.contributions().authz
        }
      ])

    settings =
      Bilimbi.Base.Settings.ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: Bilimbi.People.Workforce.Contributions.contributions().settings
        },
        %{
          descriptor: %{id: "people/skills"},
          payload: Bilimbi.People.Skills.Contributions.contributions().settings
        }
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "performance-test",
      consumers:
        Map.merge(ContributionRegistry.build!([]).consumers, %{authz: authz, settings: settings})
    })
  end

  def grant!(scope, role, company, capabilities) do
    for cap <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company, :user, @users[role], cap, true)
    end
  end

  def actor(ctx, role, company \\ 73),
    do: Bilimbi.Base.Tenancy.Authentication.sign_in(ctx.scope, @users[role], company)

  defp employee!(scope, company, number, supervisor) do
    {:ok, row} =
      Employee.create_employee(scope, company, %{
        employee_number: number,
        full_name: "Employee #{number}",
        supervisor_id: supervisor,
        status: "active"
      })

    row
  end

  def description_attrs(ctx) do
    %{
      code: "description-one",
      version: 1,
      position_id: ctx.position.id,
      position_version: 1,
      effective_from: ~D[2026-01-01],
      purpose: "Purpose",
      responsibilities: "Accountable outcomes",
      duties: "Activities",
      authority: "Company limits",
      qualifications: "Required qualifications",
      competency_links: [%{"id" => ctx.profile.id, "version" => 1}]
    }
  end

  def definition_attrs do
    %{
      code: "kpi-one",
      version: 1,
      name: "Measure one",
      purpose: "Observe outcomes",
      unit: "units",
      measure: "Verified units within the period",
      source_reference: "record-one",
      calculation_version: "v1",
      direction: "higher",
      precision: 0,
      interpretation: "Compare verified outcomes with agreed target"
    }
  end

  def target_attrs(ctx, definition) do
    %{
      definition_id: definition.id,
      employee_id: ctx.people.employee.id,
      target: "10 verified units",
      period_start: Date.utc_today(),
      period_end: Date.utc_today(),
      effective_from: Date.utc_today(),
      confidential: false
    }
  end

  def ready!(ctx) do
    manager = actor(ctx, :manager)
    reviewer = actor(ctx, :reviewer)
    {:ok, d} = Performance.draft_description(manager, 73, description_attrs(ctx))
    {:ok, d} = Performance.publish_description(manager, 73, d.id)
    {:ok, kpi} = Performance.define_kpi(manager, 73, definition_attrs())
    {:ok, t} = Performance.propose_target(manager, 73, target_attrs(ctx, kpi))
    {:ok, _} = Performance.review_target(reviewer, 73, t.id, "Target checked")
    {:ok, t} = Performance.publish_target(reviewer, 73, t.id)

    {:ok, o} =
      Performance.record_observation(manager, 73, %{
        employee_id: ctx.people.employee.id,
        window_start: Date.utc_today(),
        window_end: Date.utc_today(),
        evidence: "10 verified units recorded",
        source_reference: "measurement-one",
        source_version: "1"
      })

    Map.merge(ctx, %{description: d, definition: kpi, target: t, observation: o})
  end

  def review_attrs(ctx) do
    %{
      employee_id: ctx.people.employee.id,
      description_id: ctx.description.id,
      period_start: Date.utc_today(),
      period_end: Date.utc_today(),
      cutoff_at: DateTime.utc_now() |> DateTime.truncate(:second),
      outcome: "Agreed outcome",
      rationale: "Supported by attributable evidence",
      observation_ids: [ctx.observation.id],
      target_ids: [ctx.target.id]
    }
  end
end
