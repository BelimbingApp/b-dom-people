defmodule Bilimbi.People.Skills.Web.SkillsLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz.Actor
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Organisation
  alias Bilimbi.People.Organisation.TestFixtures, as: OrganisationFixtures
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.TestFixtures

  @view "people.skills.catalog.view"
  @manage "people.skills.catalog.manage"
  @publish "people.skills.profiles.publish"

  setup do
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    OrganisationFixtures.create_position_tables!()
    TestFixtures.create_skill_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope, actor: %Actor{type: :user, id: 91, company_id: 73, scope: scope}}
  end

  defp profile_ready(scope, code \\ "base", target \\ :company) do
    {:ok, category} =
      Skills.create_category(scope, 73, %{code: "cat-#{code}", name: "Category #{code}"})

    {:ok, skill} =
      Skills.create_skill(scope, 73, %{
        code: "skill-#{code}",
        name: "Skill #{code}",
        definition: "Defined",
        category_id: category.id
      })

    scale =
      case Skills.list_scales(scope, 73) do
        {:ok, [%{status: "published"} = scale | _]} ->
          scale

        _ ->
          {:ok, scale} = Skills.create_scale(scope, 73, %{code: "standard", name: "Standard"})

          for level <- 0..1 do
            {:ok, _} =
              Skills.put_scale_level(scope, 73, scale.id, %{
                level: level,
                name: "Level #{level}",
                anchor: "Anchor",
                authority: "Authority"
              })
          end

          {:ok, scale} = Skills.publish_scale(scope, 73, scale.id)
          scale
      end

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: code, name: "Profile #{code}", scale_id: scale.id})

    {:ok, _} =
      Skills.put_item(scope, 73, profile.id, %{
        skill_id: skill.id,
        required_level: 1,
        criticality: "critical",
        weight_percent: "100"
      })

    {:ok, _} = Skills.add_selector(scope, 73, profile.id, target)
    profile
  end

  test "skills pages require authentication and the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/skills")
    assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live("/people/skills")
  end

  test "a viewer sees empty states and no editing forms", %{conn: conn, scope: scope} do
    grant_capabilities!(@view)
    {:ok, view, _} = conn |> log_in_as() |> live("/people/skills")

    for id <- ~w(#skill-categories-empty #skill-scales-empty #skills-empty #skill-profiles-empty),
        do: assert(has_element?(view, id))

    refute has_element?(view, "#skill-category-form")
    refute has_element?(view, "#skill-scale-form")

    assert render_hook(view, "create_category", %{"category" => %{"code" => "x", "name" => "X"}}) =~
             "You cannot change this company&#39;s skills."

    assert {:ok, []} = Skills.list_categories(scope, 73)
  end

  test "an operator builds a catalog, scale and profile, and a publisher publishes it", %{
    conn: conn,
    scope: scope
  } do
    grant_capabilities!([@view, @manage, @publish])
    conn = log_in_as(conn)
    {:ok, view, _} = live(conn, "/people/skills")

    view
    |> form("#skill-category-form", category: %{code: "technical", name: "Technical"})
    |> render_submit()

    assert has_element?(view, "#skill-categories", "Technical")

    view
    |> form("#skill-form",
      skill: %{code: "welding", name: "Welding", definition: "Joins parts", critical: "true"}
    )
    |> render_submit()

    assert has_element?(view, "#skills", "Welding")

    view |> form("#skill-scale-form", scale: %{code: "standard", name: "Standard"}) |> render_submit()
    {:ok, [scale]} = Skills.list_scales(scope, 73)

    for {level, name} <- [{"0", "Not trained"}, {"1", "Competent"}] do
      view
      |> form("#skill-level-form-#{scale.id}",
        level: %{level: level, name: name, anchor: "Observed", authority: "Works"}
      )
      |> render_submit()
    end

    view
    |> element("#skill-scale-#{scale.id} button", "Publish")
    |> render_click()

    assert render(view) =~ "Scale published."

    view
    |> form("#skill-profile-form", profile: %{code: "operators", name: "Operators"})
    |> render_submit()

    {:ok, [profile]} = Skills.list_profiles(scope, 73)
    {:ok, page, _} = live(conn, "/people/skills/profiles/#{profile.id}?company_id=73")
    assert has_element?(page, "#skill-profile-items-empty")

    page
    |> form("#skill-profile-item-form",
      item: %{required_level: "1", criticality: "critical", weight_percent: "60"}
    )
    |> render_submit()

    page |> form("#skill-profile-selector-form", selector: %{target: "company"}) |> render_submit()

    page |> form("#skill-profile-publish-form", effective_from: "2026-01-01") |> render_submit()
    assert render(page) =~ "Requirement weights must total 100."

    page
    |> form("#skill-profile-item-form",
      item: %{required_level: "1", criticality: "critical", weight_percent: "100"}
    )
    |> render_submit()

    page |> form("#skill-profile-publish-form", effective_from: "2026-01-01") |> render_submit()
    assert render(page) =~ "Profile published."
    refute has_element?(page, "#skill-profile-item-form")
    assert {:ok, %{code: "operators"}} = Skills.requirements(scope, 73, nil, ~D[2026-06-01])
  end

  test "a catalog manager without the publish capability cannot publish", %{
    conn: conn,
    scope: scope,
    actor: actor
  } do
    grant_capabilities!([@view, @manage])
    profile = profile_ready(scope)
    {:ok, page, _} = conn |> log_in_as() |> live("/people/skills/profiles/#{profile.id}?company_id=73")
    refute has_element?(page, "#skill-profile-publish-form")
    assert {:error, :unauthorized} = Skills.publish_profile(actor, 73, profile.id, ~D[2026-01-01])
  end

  test "published versions supersede, never overlap and resolve by date", %{
    scope: scope,
    actor: actor
  } do
    grant_capabilities!([@view, @manage, @publish])
    v1 = profile_ready(scope)
    assert {:ok, %{status: "published"}} = Skills.publish_profile(actor, 73, v1.id, ~D[2026-01-01])

    assert {:ok, draft} = Skills.new_profile_version(scope, 73, v1.id)
    assert %{version: 2, status: "draft", items: [_], selectors: [_]} = draft

    assert {:error, :not_after_latest} =
             Skills.publish_profile(actor, 73, draft.id, ~D[2026-01-01])

    assert {:ok, _} = Skills.publish_profile(actor, 73, draft.id, ~D[2026-07-01])

    assert {:ok, %{version: 1}} = Skills.requirements(scope, 73, nil, ~D[2026-03-01])
    assert {:ok, %{version: 2}} = Skills.requirements(scope, 73, nil, ~D[2026-08-01])
    assert {:ok, nil} = Skills.requirements(scope, 73, nil, ~D[2025-12-31])

    other = profile_ready(scope, "other")

    assert {:error, :overlapping_profile} =
             Skills.publish_profile(actor, 73, other.id, ~D[2027-01-01])

    assert {:ok, %{status: "retired", effective_to: ~D[2026-12-31]}} =
             Skills.retire_profile(actor, 73, draft.id, ~D[2026-12-31])

    {:ok, v3} = Skills.new_profile_version(scope, 73, draft.id)

    assert {:error, :not_after_latest} =
             Skills.publish_profile(actor, 73, v3.id, ~D[2026-12-01])

    {:ok, _} = Skills.discard_profile(scope, 73, v3.id)

    assert {:ok, _} = Skills.publish_profile(actor, 73, other.id, ~D[2027-01-01])
    assert {:ok, %{code: "other"}} = Skills.requirements(scope, 73, nil, ~D[2027-02-01])
  end

  test "position targets use the Organisation position read", %{
    conn: conn,
    scope: scope,
    actor: actor
  } do
    grant_capabilities!([@view, @manage, @publish])
    {:ok, a} = Organisation.create_position(scope, 73, %{code: "P-A"})
    {:ok, b} = Organisation.create_position(scope, 73, %{code: "P-B"})
    first = profile_ready(scope, "first", {:position, a.id})
    second = profile_ready(scope, "second", {:position, b.id})

    conn = log_in_as(conn)
    {:ok, page, _} = live(conn, "/people/skills/profiles/#{second.id}?company_id=73")

    assert has_element?(page, "#skill-profile-selectors", "P-B")

    assert {:ok, _} = Skills.publish_profile(actor, 73, first.id, ~D[2026-01-01])
    assert {:ok, _} = Skills.publish_profile(actor, 73, second.id, ~D[2026-01-01])
    {:ok, published, _} = live(conn, "/people/skills/profiles/#{second.id}?company_id=73")
    assert has_element?(published, "#skill-profile-selectors", "P-B")
    assert {:ok, %{code: "first"}} = Skills.requirements(scope, 73, a.id, ~D[2026-02-01])
    assert {:ok, %{code: "second"}} = Skills.requirements(scope, 73, b.id, ~D[2026-02-01])
    assert {:ok, nil} = Skills.requirements(scope, 73, nil, ~D[2026-02-01])

    wide = profile_ready(scope, "wide")

    assert {:error, :overlapping_profile} =
             Skills.publish_profile(actor, 73, wide.id, ~D[2026-02-01])
  end
  defp publish_new_scale_version(scope, scale, drop_levels \\ []) do
    {:ok, draft} = Skills.new_scale_version(scope, 73, scale.id)
    for level <- drop_levels,
        do: {:ok, :ok} = Skills.delete_scale_level(scope, 73, draft.id, level)
    {:ok, published} = Skills.publish_scale(scope, 73, draft.id)
    published
  end

  test "a new profile version adopts the revised scale and publishes", %{
    scope: scope,
    actor: actor
  } do
    grant_capabilities!([@view, @manage, @publish])
    v1 = profile_ready(scope)
    {:ok, _} = Skills.publish_profile(actor, 73, v1.id, ~D[2026-01-01])
    scale_v2 = publish_new_scale_version(scope, %{id: v1.scale_id})

    assert {:ok, %{scale_id: scale_id, missing_levels: []} = draft} =
             Skills.new_profile_version(scope, 73, v1.id)

    assert scale_id == scale_v2.id
    assert {:ok, %{status: "published"}} =
             Skills.publish_profile(actor, 73, draft.id, ~D[2026-07-01])
  end

  test "a draft keeps its scale until required levels exist on the revised scale", %{
    conn: conn,
    scope: scope,
    actor: actor
  } do
    grant_capabilities!([@view, @manage, @publish])
    {:ok, category} = Skills.create_category(scope, 73, %{code: "cat", name: "Category"})

    {:ok, skill} =
      Skills.create_skill(scope, 73, %{
        code: "skill",
        name: "Skill",
        definition: "Defined",
        category_id: category.id
      })

    {:ok, scale} = Skills.create_scale(scope, 73, %{code: "deep", name: "Deep"})

    for level <- 0..2 do
      {:ok, _} =
        Skills.put_scale_level(scope, 73, scale.id, %{
          level: level,
          name: "Level #{level}",
          anchor: "Anchor",
          authority: "Authority"
        })
    end

    {:ok, scale} = Skills.publish_scale(scope, 73, scale.id)

    {:ok, v1} =
      Skills.create_profile(scope, 73, %{code: "deep", name: "Deep", scale_id: scale.id})

    item = %{skill_id: skill.id, criticality: "critical", weight_percent: "100"}
    {:ok, _} = Skills.put_item(scope, 73, v1.id, Map.put(item, :required_level, 2))
    {:ok, _} = Skills.add_selector(scope, 73, v1.id, :company)
    {:ok, _} = Skills.publish_profile(actor, 73, v1.id, ~D[2026-01-01])
    scale_v2 = publish_new_scale_version(scope, scale, [2])

    assert {:ok, %{scale_id: scale_id, missing_levels: [2]} = draft} =
             Skills.new_profile_version(scope, 73, v1.id)

    assert scale_id == scale.id

    {:ok, page, _} =
      conn |> log_in_as() |> live("/people/skills/profiles/#{draft.id}?company_id=73")

    assert page |> form("#skill-profile-scale-form", scale_id: scale_v2.id) |> render_submit() =~
             "Each required level must exist on the scale"

    assert {:error, :level_not_on_scale} =
             Skills.update_profile(scope, 73, draft.id, %{scale_id: scale_v2.id})

    {:ok, _} = Skills.put_item(scope, 73, draft.id, Map.put(item, :required_level, 1))

    assert page |> form("#skill-profile-scale-form", scale_id: scale_v2.id) |> render_submit() =~
             "Scale changed."

    assert {:ok, %{scale_id: moved}} = Skills.get_profile(scope, 73, draft.id)
    assert moved == scale_v2.id
    assert {:ok, %{status: "published"}} =
             Skills.publish_profile(actor, 73, draft.id, ~D[2026-07-01])
  end

  test "publish and retire events are refused without the publish capability", %{
    conn: conn,
    scope: scope
  } do
    grant_capabilities!([@view, @manage])
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Publisher"})
    grant_capabilities!([@publish], user_id: 92)
    publisher = %Actor{type: :user, id: 92, company_id: 73, scope: scope}
    published = profile_ready(scope)
    {:ok, _} = Skills.publish_profile(publisher, 73, published.id, ~D[2026-01-01])
    draft = profile_ready(scope, "other", :company)
    conn = log_in_as(conn)

    {:ok, page, _} = live(conn, "/people/skills/profiles/#{draft.id}?company_id=73")

    assert render_hook(page, "publish", %{"effective_from" => "2027-01-01"}) =~
             "You cannot publish or retire this company&#39;s profiles."

    {:ok, page, _} = live(conn, "/people/skills/profiles/#{published.id}?company_id=73")

    assert render_hook(page, "retire", %{"effective_to" => "2026-12-31"}) =~
             "You cannot publish or retire this company&#39;s profiles."

    assert {:ok, %{status: "draft"}} = Skills.get_profile(scope, 73, draft.id)
    assert {:ok, %{status: "published"}} = Skills.get_profile(scope, 73, published.id)
  end
end
