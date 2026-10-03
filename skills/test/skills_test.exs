defmodule Bilimbi.People.SkillsTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Settings.Contributions, as: SettingsContributions
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.Contributions
  alias Bilimbi.People.Skills.TestFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @manage "people.skills.catalog.manage"
  @publish "people.skills.profiles.publish"
  @operator_grants [@manage, @publish, "admin.company.tenant-wide.manage"]
  alias Ecto.Adapters.SQL

  defmodule PositionReader do
    @moduledoc false
    alias Bilimbi.People.Workforce.{Position, Reference}

    def positions(_scope, company_id, _as_of, options) do
      if Keyword.fetch!(options, :page) == 1 do
        {:ok,
         for id <- [501, 502] do
           %Position{
             reference: ref(:position, id),
             company_reference: ref(:company, company_id),
             platform_company_id: company_id,
             workforce_company_id: company_id,
             code: "P#{id}",
             title: "Position #{id}",
             vacant?: true
           }
         end}
      else
        {:ok, []}
      end
    end

    defp ref(type, id),
      do: %Reference{source_id: "people/native", type: type, stable_id: to_string(id)}
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        }
      ])

    AuthorizationFixtures.install_snapshot!("skills-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    on_exit(fn -> Workforce.unregister_position_reader(PositionReader) end)
    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    TestFixtures.create_skill_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    :ok = Employee.ensure_system_types()
    {:ok, system} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Catalog operator"})

    # Catalog writes authorize the scope's actor, so the tests act as an
    # operator who holds the catalog grants and tenant-wide company reach.
    scope = AuthorizationFixtures.sign_in!(system, 73, 91, @operator_grants)
    %{scope: scope, system: system, other_scope: other_scope}
  end

  defp category(scope, company_id \\ 73, code \\ "technical") do
    {:ok, category} = Skills.create_category(scope, company_id, %{code: code, name: "Technical"})
    category
  end

  defp skill(scope, category, code \\ "welding") do
    {:ok, skill} =
      Skills.create_skill(scope, 73, %{
        code: code,
        name: String.capitalize(code),
        definition: "Joins parts to the documented standard.",
        category_id: category.id
      })

    skill
  end

  defp published_scale(scope, code \\ "standard") do
    {:ok, scale} = Skills.create_scale(scope, 73, %{code: code, name: "Standard"})

    for {name, level} <- Enum.with_index(~w(None Aware Competent)) do
      {:ok, _} =
        Skills.put_scale_level(scope, 73, scale.id, %{
          level: level,
          name: name,
          anchor: "Observed #{name}",
          authority: "Works at #{name}"
        })
    end

    {:ok, scale} = Skills.publish_scale(scope, 73, scale.id)
    scale
  end

  test "catalog writes authorize the scope's actor when they run", %{
    scope: scope,
    system: system
  } do
    # A system scope names nobody.
    assert {:error, :unauthorized} =
             Skills.create_category(system, 73, %{code: "technical", name: "Technical"})

    # A signed-in user without the grant is refused.
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Viewer", email: "v@example.com"})
    viewer = AuthorizationFixtures.sign_in(system, 92, 73)

    assert {:error, :unauthorized} =
             Skills.create_category(viewer, 73, %{code: "technical", name: "Technical"})

    category = category(scope)
    skill = skill(scope, category)
    scale = published_scale(scope)

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: "base", name: "Base", scale_id: scale.id})

    {:ok, _} =
      Skills.put_item(scope, 73, profile.id, %{
        skill_id: skill.id,
        required_level: 1,
        criticality: "critical",
        weight_percent: "100"
      })

    {:ok, _} = Skills.add_selector(scope, 73, profile.id, :company)

    # Publishing needs its own capability; the publisher is recorded from the scope.
    :ok = AuthorizationFixtures.revoke!(system, 73, 91, @publish)
    assert {:error, :unauthorized} = Skills.publish_profile(scope, 73, profile.id, ~D[2026-01-01])
    :ok = AuthorizationFixtures.grant!(system, 73, 91, @publish)

    assert {:ok, %{status: "published"}} =
             Skills.publish_profile(scope, 73, profile.id, ~D[2026-01-01])

    # A grant revoked after sign-in is refused on the next write, and nothing changes.
    :ok = AuthorizationFixtures.revoke!(system, 73, 91, @manage)
    assert {:error, :unauthorized} = Skills.set_skill_active(scope, 73, skill.id, false)
    assert {:error, :unauthorized} = Skills.create_scale(scope, 73, %{code: "x", name: "X"})
    assert {:ok, [%{active: true}]} = Skills.list_skills(system, 73)
    assert {:ok, [_]} = Skills.list_scales(system, 73)

    # Retiring needs the publish grant, which the operator still holds.
    assert {:ok, %{status: "retired"}} =
             Skills.retire_profile(scope, 73, profile.id, ~D[2026-12-31])
  end

  test "a new company has an empty catalog", %{scope: scope} do
    assert {:ok, []} = Skills.list_categories(scope, 73)
    assert {:ok, []} = Skills.list_skills(scope, 73)
    assert {:ok, []} = Skills.list_scales(scope, 73)
    assert {:ok, []} = Skills.list_profiles(scope, 73)
    assert {:ok, nil} = Skills.requirements(scope, 73, nil, ~D[2026-01-01])
  end

  test "sibling-tenant and missing companies are indistinguishable", %{
    scope: scope,
    other_scope: other_scope
  } do
    category(scope)
    assert {:error, :not_found} = Skills.list_categories(other_scope, 73)
    assert {:error, :not_found} = Skills.list_categories(scope, 75)
    assert {:error, :not_found} = Skills.list_categories(scope, 9_999)
    assert {:ok, []} = Skills.list_categories(scope, 74)
  end

  test "category codes are validated and unique per company", %{scope: scope} do
    category(scope)

    assert {:error, %Ecto.Changeset{}} =
             Skills.create_category(scope, 73, %{code: "technical", name: "Again"})

    assert {:error, %Ecto.Changeset{}} =
             Skills.create_category(scope, 73, %{code: "Has Space", name: "Bad"})

    assert {:ok, _} = Skills.create_category(scope, 74, %{code: "technical", name: "Other"})
  end

  test "a category with active skills cannot be deactivated", %{scope: scope} do
    category = category(scope)
    skill = skill(scope, category)

    assert {:error, :category_in_use} = Skills.set_category_active(scope, 73, category.id, false)
    assert {:ok, %{active: false}} = Skills.set_skill_active(scope, 73, skill.id, false)
    assert {:ok, %{active: false}} = Skills.set_category_active(scope, 73, category.id, false)

    assert {:error, :category_unavailable} =
             Skills.set_skill_active(scope, 73, skill.id, true)

    assert {:error, :category_unavailable} =
             Skills.create_skill(scope, 73, %{
               code: "cutting",
               name: "Cutting",
               definition: "Cuts",
               category_id: category.id
             })
  end

  test "a skill needs a category in its own company", %{scope: scope} do
    other = category(scope, 74)

    assert {:error, :category_unavailable} =
             Skills.create_skill(scope, 73, %{
               code: "welding",
               name: "Welding",
               definition: "Joins parts",
               category_id: other.id
             })
  end

  test "an inactive skill still cannot move to another company's category", %{scope: scope} do
    skill = skill(scope, category(scope))
    other = category(scope, 74)
    {:ok, _} = Skills.set_skill_active(scope, 73, skill.id, false)

    assert {:error, :category_unavailable} =
             Skills.update_skill(scope, 73, skill.id, %{category_id: other.id})
  end

  test "a skill code is its stable identity", %{scope: scope} do
    skill = skill(scope, category(scope))

    assert {:ok, %{code: "welding", name: "Arc welding", reassessment_months: 12}} =
             Skills.update_skill(scope, 73, skill.id, %{
               code: "renamed",
               name: "Arc welding",
               reassessment_months: 12
             })

    assert_raise Postgrex.Error, ~r/code and company are stable/, fn ->
      SQL.query!(Repo, "UPDATE people_skills SET code = 'renamed' WHERE id = $1", [skill.id])
    end
  end

  test "publishing a scale needs contiguous levels from zero with distinct names", %{
    scope: scope
  } do
    {:ok, scale} = Skills.create_scale(scope, 73, %{code: "standard", name: "Standard"})
    assert {:error, :invalid_levels} = Skills.publish_scale(scope, 73, scale.id)

    level = %{name: "None", anchor: "Not observed", authority: "None"}
    {:ok, _} = Skills.put_scale_level(scope, 73, scale.id, Map.put(level, :level, 0))
    {:ok, _} = Skills.put_scale_level(scope, 73, scale.id, Map.put(level, :level, 2))
    assert {:error, :invalid_levels} = Skills.publish_scale(scope, 73, scale.id)

    {:ok, _} = Skills.delete_scale_level(scope, 73, scale.id, 2)
    {:ok, _} = Skills.put_scale_level(scope, 73, scale.id, Map.put(level, :level, 1))
    assert {:error, :invalid_levels} = Skills.publish_scale(scope, 73, scale.id)

    {:ok, _} =
      Skills.put_scale_level(scope, 73, scale.id, %{level | name: "Aware"} |> Map.put(:level, 1))

    assert {:ok, %{status: "published", levels: [_, _]}} =
             Skills.publish_scale(scope, 73, scale.id)
  end

  test "a published scale is immutable and a new version supersedes it", %{scope: scope} do
    v1 = published_scale(scope)

    assert {:error, :not_draft} =
             Skills.put_scale_level(scope, 73, v1.id, %{
               level: 3,
               name: "Expert",
               anchor: "Leads",
               authority: "Signs off"
             })

    assert_raise Postgrex.Error, ~r/levels are immutable/, fn ->
      SQL.query!(Repo, "DELETE FROM people_skill_scale_levels WHERE scale_id = $1", [v1.id])
    end

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      SQL.query!(Repo, "UPDATE people_skill_scales SET name = 'x' WHERE id = $1", [v1.id])
    end

    assert {:ok, %{version: 2, status: "draft", levels: levels}} =
             v2 = Skills.new_scale_version(scope, 73, v1.id)

    assert length(levels) == 3
    assert {:error, :draft_exists} = Skills.new_scale_version(scope, 73, v1.id)
    {:ok, v2} = v2
    {:ok, _} = Skills.publish_scale(scope, 73, v2.id)

    assert {:ok, [%{version: 2, status: "published"}, %{version: 1, status: "retired"}]} =
             Skills.list_scales(scope, 73)
  end

  test "profile drafts validate skills, levels and targets", %{scope: scope} do
    skill = skill(scope, category(scope))
    scale = published_scale(scope)
    {:ok, draft_scale} = Skills.create_scale(scope, 73, %{code: "other", name: "Other"})

    assert {:error, :scale_unavailable} =
             Skills.create_profile(scope, 73, %{
               code: "base",
               name: "Base",
               scale_id: draft_scale.id
             })

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: "base", name: "Base", scale_id: scale.id})

    item = %{skill_id: skill.id, criticality: "critical", weight_percent: "100"}

    assert {:error, :level_not_on_scale} =
             Skills.put_item(scope, 73, profile.id, Map.put(item, :required_level, 5))

    assert {:ok, %{sequence: 1, required_level: 2}} =
             Skills.put_item(scope, 73, profile.id, Map.put(item, :required_level, 2))

    assert {:ok, %{sequence: 1, required_level: 1}} =
             Skills.put_item(scope, 73, profile.id, Map.put(item, :required_level, 1))

    assert {:error, %Ecto.Changeset{}} =
             Skills.put_item(
               scope,
               73,
               profile.id,
               item |> Map.merge(%{required_level: 1, weight_percent: "10.555"})
             )

    assert {:ok, %{selector_type: "company"}} =
             Skills.add_selector(scope, 73, profile.id, :company)

    assert {:error, :duplicate_selector} = Skills.add_selector(scope, 73, profile.id, :company)

    assert {:error, :position_unavailable} =
             Skills.add_selector(scope, 73, profile.id, {:position, 501})

    assert {:error, :code_exists} =
             Skills.create_profile(scope, 73, %{code: "base", name: "Again", scale_id: scale.id})
  end

  test "position targets come from the registered position read", %{scope: scope} do
    :ok = Workforce.register_position_reader(PositionReader)
    scale = published_scale(scope)

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: "operators", name: "Operators", scale_id: scale.id})

    assert {:ok, [%{id: 501}, %{id: 502}]} = Skills.position_options(scope, 73)
    assert {:ok, _} = Skills.add_selector(scope, 73, profile.id, {:position, 501})

    assert {:error, :position_unavailable} =
             Skills.add_selector(scope, 73, profile.id, {:position, 9})

    assert {:error, :mixed_selectors} = Skills.add_selector(scope, 73, profile.id, :company)
  end

  test "items reorder and resequence without gaps", %{scope: scope} do
    category = category(scope)
    skills = for code <- ~w(alpha beta gamma), do: skill(scope, category, code)
    scale = published_scale(scope)
    {:ok, profile} = Skills.create_profile(scope, 73, %{code: "p", name: "P", scale_id: scale.id})

    for skill <- skills do
      {:ok, _} =
        Skills.put_item(scope, 73, profile.id, %{
          skill_id: skill.id,
          required_level: 1,
          criticality: "essential",
          weight_percent: 10
        })
    end

    {:ok, %{items: [first, second, _]}} = Skills.get_profile(scope, 73, profile.id)
    {:ok, _} = Skills.move_item(scope, 73, profile.id, second.id, :up)
    {:ok, _} = Skills.remove_item(scope, 73, profile.id, first.id)
    {:ok, %{items: items}} = Skills.get_profile(scope, 73, profile.id)

    assert Enum.map(items, &{&1.skill_id, &1.sequence}) == [
             {second.skill_id, 1},
             {List.last(skills).id, 2}
           ]
  end

  test "every Skills leaf hangs on a People container and names a declared capability" do
    contributions = Contributions.contributions()
    containers = SettingsContributions.contributions().menu |> Enum.map(& &1.id) |> MapSet.new()

    assert Enum.map(contributions.menu, & &1.id) ==
             Enum.uniq(Enum.map(contributions.menu, & &1.id))

    for leaf <- contributions.menu do
      assert MapSet.member?(containers, leaf.parent)
      assert leaf.capability in contributions.authz.capabilities
    end

    assert Enum.map(contributions.menu, & &1.parent) |> Enum.uniq() |> Enum.sort() ==
             ["people.development", "people.my_work", "people.settings"]
  end
end
