defmodule Bilimbi.People.Skills do
  @moduledoc """
  Company-scoped skill catalog, versioned proficiency scales and versioned
  requirement profiles.

  Every operation takes a validated tenant scope and an explicit platform
  company ID whose workforce company must be current. Every write authorizes
  its own capability for the scope's signed-in actor when it runs, through
  `Bilimbi.People.Workforce.Authorization`: catalog, scale and profile-draft
  writes need `people.skills.catalog.manage`, publishing and retiring a
  requirement profile need `people.skills.profiles.publish`, and a system
  scope is refused. Assessments, reassessment requests, development actions
  and reminders take a login actor, whose capabilities, reporting line and
  independence from the employee decide what they may do, checked on each
  call. Callers never query the schemas directly.
  """
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company

  alias Bilimbi.Base.Queue

  alias Bilimbi.People.Skills.{
    Actions,
    Assessments,
    Category,
    Policy,
    Reassessments,
    ReminderWorker,
    Reminders,
    Standing,
    Profile,
    ProfileItem,
    ProfileSelector,
    Scale,
    ScaleLevel,
    Skill
  }

  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce.ReadResult

  @publish_capability "people.skills.profiles.publish"
  @manage_capability "people.skills.catalog.manage"
  @reminders_capability "people.skills.reminders.send"
  @position_page_size 100
  @max_position_pages 20

  def publish_capability, do: @publish_capability

  ## Categories

  def list_categories(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(c in Tenancy.scope_query(Category, scope),
           where: c.company_id == ^company_id,
           order_by: [desc: c.active, asc: c.name, asc: c.id]
         )
       )
       |> Enum.map(&category_view/1)}
    end
  end

  def create_category(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      %Category{tenant_id: Scope.tenant_id(scope), company_id: company_id, active: true}
      |> Category.create_changeset(stringify(attrs))
      |> Repo.insert()
      |> view_result(&category_view/1)
    end
  end

  def update_category(%Scope{} = scope, company_id, category_id, attrs) when is_map(attrs) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id),
         %Category{} = category <- get(Category, scope, company_id, category_id) do
      category
      |> Category.changeset(Map.take(stringify(attrs), ~w(name description)))
      |> Repo.update()
      |> view_result(&category_view/1)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Deactivation is refused while the category has active skills."
  def set_category_active(%Scope{} = scope, company_id, category_id, active)
      when is_boolean(active) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        category = lock(Category, scope, company_id, category_id) || Repo.rollback(:not_found)

        if not active and active_skills?(scope, category.id),
          do: Repo.rollback(:category_in_use)

        category
        |> Ecto.Changeset.change(active: active)
        |> Repo.update()
        |> unwrap_view(&category_view/1)
      end)
    end
  end

  ## Skills

  def list_skills(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(s in Tenancy.scope_query(Skill, scope),
           where: s.company_id == ^company_id,
           order_by: [desc: s.active, asc: s.name, asc: s.id]
         )
       )
       |> Enum.map(&skill_view/1)}
    end
  end

  @doc "Adds an active skill under an active category of the same company."
  def create_skill(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        require_active_category(scope, company_id, attrs["category_id"])

        %Skill{tenant_id: Scope.tenant_id(scope), company_id: company_id, active: true}
        |> Skill.create_changeset(attrs)
        |> Repo.insert()
        |> unwrap_view(&skill_view/1)
      end)
    end
  end

  @doc "Revises a skill; its code is the stable identity and never changes."
  def update_skill(%Scope{} = scope, company_id, skill_id, attrs) when is_map(attrs) do
    attrs = Map.drop(stringify(attrs), ~w(code active))

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        skill = lock(Skill, scope, company_id, skill_id) || Repo.rollback(:not_found)
        category_id = Map.get(attrs, "category_id", skill.category_id)
        require_category(scope, company_id, category_id, skill.active)

        skill
        |> Skill.changeset(attrs)
        |> Repo.update()
        |> unwrap_view(&skill_view/1)
      end)
    end
  end

  @doc "Reactivation needs an active category; history is never deleted."
  def set_skill_active(%Scope{} = scope, company_id, skill_id, active) when is_boolean(active) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        skill = lock(Skill, scope, company_id, skill_id) || Repo.rollback(:not_found)
        if active, do: require_active_category(scope, company_id, skill.category_id)

        skill
        |> Ecto.Changeset.change(active: active)
        |> Repo.update()
        |> unwrap_view(&skill_view/1)
      end)
    end
  end

  ## Proficiency scales

  @doc "Scale versions with their levels, newest version first within a code."
  def list_scales(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      scales =
        Repo.all(
          from(s in Tenancy.scope_query(Scale, scope),
            where: s.company_id == ^company_id,
            order_by: [asc: s.code, desc: s.version]
          )
        )

      levels = levels_by_scale(scope, Enum.map(scales, & &1.id))
      {:ok, Enum.map(scales, &scale_view(&1, Map.get(levels, &1.id, [])))}
    end
  end

  @doc "Starts version 1 of a new scale code as a draft without levels."
  def create_scale(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        lock_company(scope, company_id)

        if code_exists?(Scale, scope, company_id, attrs["code"]),
          do: Repo.rollback(:code_exists)

        %Scale{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          version: 1,
          status: "draft"
        }
        |> Scale.changeset(Map.take(attrs, ~w(code name)))
        |> Repo.insert()
        |> unwrap_view(&scale_view(&1, []))
      end)
    end
  end

  @doc "Drafts the next version of a scale code, copying the chosen version's levels."
  def new_scale_version(%Scope{} = scope, company_id, scale_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        lock_company(scope, company_id)
        source = get(Scale, scope, company_id, scale_id) || Repo.rollback(:not_found)
        if open_draft?(Scale, scope, company_id, source.code), do: Repo.rollback(:draft_exists)

        draft =
          %Scale{
            tenant_id: source.tenant_id,
            company_id: company_id,
            code: source.code,
            name: source.name,
            version: next_version(Scale, scope, company_id, source.code),
            status: "draft"
          }
          |> Repo.insert!()

        levels =
          for level <- Map.get(levels_by_scale(scope, [source.id]), source.id, []) do
            Repo.insert!(%ScaleLevel{
              tenant_id: source.tenant_id,
              company_id: company_id,
              scale_id: draft.id,
              level: level.level,
              name: level.name,
              anchor: level.anchor,
              authority: level.authority
            })
          end

        scale_view(draft, levels)
      end)
    end
  end

  def rename_scale(%Scope{} = scope, company_id, scale_id, name) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        scale = lock_draft(Scale, scope, company_id, scale_id)

        scale
        |> Scale.changeset(%{"name" => name})
        |> Repo.update()
        |> unwrap_view(&scale_view(&1, []))
      end)
    end
  end

  @doc "Adds or replaces one level of a draft scale, keyed by its level number."
  def put_scale_level(%Scope{} = scope, company_id, scale_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id),
         {:ok, level} <- parse_integer(attrs["level"]) do
      transact(fn ->
        scale = lock_draft(Scale, scope, company_id, scale_id)

        existing =
          Repo.one(
            from(l in Tenancy.scope_query(ScaleLevel, scope),
              where: l.scale_id == ^scale.id and l.level == ^level
            )
          ) ||
            %ScaleLevel{
              tenant_id: scale.tenant_id,
              company_id: company_id,
              scale_id: scale.id
            }

        existing
        |> ScaleLevel.changeset(Map.put(attrs, "level", level))
        |> Repo.insert_or_update()
        |> unwrap_view(&level_view/1)
      end)
    end
  end

  def delete_scale_level(%Scope{} = scope, company_id, scale_id, level) when is_integer(level) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        scale = lock_draft(Scale, scope, company_id, scale_id)

        {count, _} =
          Repo.delete_all(
            from(l in Tenancy.scope_query(ScaleLevel, scope),
              where: l.scale_id == ^scale.id and l.level == ^level
            )
          )

        if count == 0, do: Repo.rollback(:not_found), else: :ok
      end)
    end
  end

  @doc """
  Publishes a draft whose levels run contiguously from 0 with at least two
  levels and distinct names. The previously published version of the code
  is retired in the same transaction, so one version is current.
  """
  def publish_scale(%Scope{} = scope, company_id, scale_id) do
    with {:ok, actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        lock_company(scope, company_id)
        scale = lock_draft(Scale, scope, company_id, scale_id)
        levels = Map.get(levels_by_scale(scope, [scale.id]), scale.id, [])
        validate_levels(levels) || Repo.rollback(:invalid_levels)
        now = now()

        for current <- published(Scale, scope, company_id, scale.code),
            do:
              current
              |> Ecto.Changeset.change(status: "retired", retired_at: now)
              |> Repo.update!()

        scale
        |> Ecto.Changeset.change(
          status: "published",
          published_at: now,
          actor_user_id: actor.id
        )
        |> Repo.update()
        |> unwrap_view(&scale_view(&1, levels))
      end)
    end
  end

  def retire_scale(%Scope{} = scope, company_id, scale_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        scale = lock(Scale, scope, company_id, scale_id) || Repo.rollback(:not_found)
        if scale.status != "published", do: Repo.rollback(:not_published)

        scale
        |> Ecto.Changeset.change(status: "retired", retired_at: now())
        |> Repo.update()
        |> unwrap_view(&scale_view(&1, []))
      end)
    end
  end

  @doc "Discards a draft scale that no requirement profile uses."
  def discard_scale(%Scope{} = scope, company_id, scale_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        scale = lock_draft(Scale, scope, company_id, scale_id)

        if Repo.exists?(
             from(p in Tenancy.scope_query(Profile, scope), where: p.scale_id == ^scale.id)
           ),
           do: Repo.rollback(:scale_in_use)

        Repo.delete_all(
          from(l in Tenancy.scope_query(ScaleLevel, scope), where: l.scale_id == ^scale.id)
        )

        Repo.delete!(scale)
        :ok
      end)
    end
  end

  ## Requirement profiles

  def list_profiles(%Scope{} = scope, company_id) do
    with {:ok, _company} <- current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(p in Tenancy.scope_query(Profile, scope),
           where: p.company_id == ^company_id,
           order_by: [asc: p.code, desc: p.version]
         )
       )
       |> Enum.map(&profile_view/1)}
    end
  end

  @doc "One profile version with its ordered items and selectors."
  def get_profile(%Scope{} = scope, company_id, profile_id) do
    with {:ok, _company} <- current_company(scope, company_id),
         %Profile{} = profile <- get(Profile, scope, company_id, profile_id) do
      {:ok, full_profile_view(scope, profile)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Starts version 1 of a new profile code against a published scale."
  def create_profile(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        lock_company(scope, company_id)
        require_published_scale(scope, company_id, attrs["scale_id"])

        if code_exists?(Profile, scope, company_id, attrs["code"]),
          do: Repo.rollback(:code_exists)

        %Profile{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          version: 1,
          status: "draft"
        }
        |> Profile.changeset(Map.take(attrs, ~w(code name scale_id)))
        |> Repo.insert()
        |> unwrap_view(&profile_view/1)
      end)
    end
  end

  @doc """
  Renames a draft or moves it to another published scale. Moving scales
  requires every item's level to exist on the new scale.
  """
  def update_profile(%Scope{} = scope, company_id, profile_id, attrs) when is_map(attrs) do
    attrs = Map.take(stringify(attrs), ~w(name scale_id))

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)

        if Map.has_key?(attrs, "scale_id") do
          scale = require_published_scale(scope, company_id, attrs["scale_id"])
          levels = scale_level_numbers(scope, scale.id)

          if Enum.any?(items(scope, profile.id), &(&1.required_level not in levels)),
            do: Repo.rollback(:level_not_on_scale)
        end

        profile
        |> Profile.changeset(attrs)
        |> Repo.update()
        |> unwrap_view(&profile_view/1)
      end)
    end
  end

  @doc """
  Drafts the next version of a profile code, copying items and selectors.
  The draft adopts the published version of the source's scale code when
  every required level exists on it; otherwise it keeps the source's scale
  and `missing_levels` lists the required levels that version lacks.
  """
  def new_profile_version(%Scope{} = scope, company_id, profile_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        lock_company(scope, company_id)
        source = get(Profile, scope, company_id, profile_id) || Repo.rollback(:not_found)
        if open_draft?(Profile, scope, company_id, source.code), do: Repo.rollback(:draft_exists)
        source_items = items(scope, source.id)
        {scale_id, missing} = current_scale(scope, company_id, source.scale_id, source_items)

        draft =
          Repo.insert!(%Profile{
            tenant_id: source.tenant_id,
            company_id: company_id,
            code: source.code,
            name: source.name,
            version: next_version(Profile, scope, company_id, source.code),
            status: "draft",
            scale_id: scale_id
          })

        for record <- source_items ++ selectors(scope, source.id),
            do: Repo.insert!(copy(record, draft.id))

        scope |> full_profile_view(draft) |> Map.put(:missing_levels, missing)
      end)
    end
  end

  @doc """
  Adds a skill requirement to a draft, or replaces the requirement for that
  skill. The skill must be active in the same company and the required level
  must exist on the profile's scale.
  """
  def put_item(%Scope{} = scope, company_id, profile_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id),
         {:ok, skill_id} <- parse_integer(attrs["skill_id"]),
         {:ok, level} <- parse_integer(attrs["required_level"]) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)
        skill = get(Skill, scope, company_id, skill_id)
        if skill == nil or not skill.active, do: Repo.rollback(:skill_unavailable)

        if level not in scale_level_numbers(scope, profile.scale_id),
          do: Repo.rollback(:level_not_on_scale)

        existing = Enum.find(items(scope, profile.id), &(&1.skill_id == skill_id))

        (existing ||
           %ProfileItem{
             tenant_id: profile.tenant_id,
             company_id: company_id,
             profile_id: profile.id,
             skill_id: skill_id,
             sequence: length(items(scope, profile.id)) + 1
           })
        |> ProfileItem.changeset(Map.put(attrs, "required_level", level))
        |> Repo.insert_or_update()
        |> unwrap_view(&item_view/1)
      end)
    end
  end

  @doc "Removes a requirement from a draft and closes the gap in the sequence."
  def remove_item(%Scope{} = scope, company_id, profile_id, item_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)
        {removed, kept} = Enum.split_with(items(scope, profile.id), &(&1.id == item_id))
        if removed == [], do: Repo.rollback(:not_found)
        Repo.delete!(hd(removed))
        resequence(kept)
        :ok
      end)
    end
  end

  @doc "Moves a draft requirement one place up or down."
  def move_item(%Scope{} = scope, company_id, profile_id, item_id, direction)
      when direction in [:up, :down] do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)
        current = items(scope, profile.id)
        index = Enum.find_index(current, &(&1.id == item_id)) || Repo.rollback(:not_found)
        target = if direction == :up, do: index - 1, else: index + 1

        if target in 0..(length(current) - 1)//1 do
          current
          |> List.replace_at(index, Enum.at(current, target))
          |> List.replace_at(target, Enum.at(current, index))
          |> resequence()
        end

        :ok
      end)
    end
  end

  @doc """
  Targets a draft at the whole company, or at one position that the
  Organisation position read exposes. A profile targets either the company
  or a set of positions, never both.
  """
  def add_selector(%Scope{} = scope, company_id, profile_id, target)
      when target == :company or (is_tuple(target) and elem(target, 0) == :position) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id),
         :ok <- validate_target(scope, company_id, target) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)
        type = if target == :company, do: "company", else: "position"
        existing = selectors(scope, profile.id)

        cond do
          Enum.any?(existing, &(&1.selector_type != type)) ->
            Repo.rollback(:mixed_selectors)

          Enum.any?(
            existing,
            &(&1.selector_type == type and &1.position_id == position_id(target))
          ) ->
            Repo.rollback(:duplicate_selector)

          true ->
            %ProfileSelector{
              tenant_id: profile.tenant_id,
              company_id: company_id,
              profile_id: profile.id,
              selector_type: type,
              position_id: position_id(target)
            }
            |> Repo.insert()
            |> unwrap_view(&selector_view/1)
        end
      end)
    end
  end

  def add_selector(%Scope{}, _company_id, _profile_id, _target), do: {:error, :invalid_selector}

  def remove_selector(%Scope{} = scope, company_id, profile_id, selector_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)

        selector =
          Enum.find(selectors(scope, profile.id), &(&1.id == selector_id)) ||
            Repo.rollback(:not_found)

        Repo.delete!(selector)
        :ok
      end)
    end
  end

  def discard_profile(%Scope{} = scope, company_id, profile_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability),
         {:ok, _company} <- current_company(scope, company_id) do
      transact(fn ->
        profile = lock_draft(Profile, scope, company_id, profile_id)

        Repo.delete_all(
          from(i in Tenancy.scope_query(ProfileItem, scope), where: i.profile_id == ^profile.id)
        )

        Repo.delete_all(
          from(s in Tenancy.scope_query(ProfileSelector, scope),
            where: s.profile_id == ^profile.id
          )
        )

        Repo.delete!(profile)
        :ok
      end)
    end
  end

  @doc """
  Publishes a draft from `effective_from`; the scope's actor needs the publish
  capability for the company now. The draft needs at least one
  requirement and one selector, weights totalling 100, active skills, levels
  on a published scale and positions still exposed by Organisation. It must
  start after the latest published version of its code, which it retires the
  day before, and it may not target anyone that another code's published or
  retired version targets from that date on.
  """
  def publish_profile(%Scope{} = scope, company_id, profile_id, effective_from) do
    with {:ok, actor} <- Authorization.authorize(scope, company_id, @publish_capability),
         {:ok, _company} <- current_company(scope, company_id),
         {:ok, effective_from} <- parse_date(effective_from) do
      transact(fn ->
        lock_company(scope, company_id)
        profile = lock_draft(Profile, scope, company_id, profile_id)
        items = items(scope, profile.id)
        selectors = selectors(scope, profile.id)
        :ok = validate_publishable(scope, company_id, profile, items, selectors)
        previous = published(Profile, scope, company_id, profile.code)

        if not after_code_history?(scope, company_id, profile.code, effective_from),
          do: Repo.rollback(:not_after_latest)

        if overlapping?(scope, company_id, profile, selectors, effective_from),
          do: Repo.rollback(:overlapping_profile)

        now = now()

        for current <- previous do
          current
          |> Ecto.Changeset.change(
            status: "retired",
            retired_at: now,
            effective_to: Date.add(effective_from, -1)
          )
          |> Repo.update!()
        end

        profile
        |> Ecto.Changeset.change(
          status: "published",
          effective_from: effective_from,
          published_at: now,
          actor_user_id: actor.id
        )
        |> Repo.update()
        |> unwrap_view(&profile_view/1)
      end)
    end
  end

  @doc "Retires a published profile after its last effective day."
  def retire_profile(%Scope{} = scope, company_id, profile_id, effective_to) do
    with {:ok, actor} <- Authorization.authorize(scope, company_id, @publish_capability),
         {:ok, _company} <- current_company(scope, company_id),
         {:ok, effective_to} <- parse_date(effective_to) do
      transact(fn ->
        profile = lock(Profile, scope, company_id, profile_id) || Repo.rollback(:not_found)
        if profile.status != "published", do: Repo.rollback(:not_published)

        if Date.compare(effective_to, profile.effective_from) == :lt,
          do: Repo.rollback(:invalid_date)

        profile
        |> Ecto.Changeset.change(
          status: "retired",
          retired_at: now(),
          effective_to: effective_to,
          actor_user_id: actor.id
        )
        |> Repo.update()
        |> unwrap_view(&profile_view/1)
      end)
    end
  end

  @doc """
  The requirements in force on `as_of` for a company, optionally for one
  position. At most one published or retired version matches; it returns
  `{:ok, nil}` when none does.
  """
  def requirements(%Scope{} = scope, company_id, position_id, %Date{} = as_of)
      when is_nil(position_id) or is_integer(position_id) do
    target =
      if position_id,
        do:
          dynamic(
            [_p, s],
            s.selector_type == "company" or
              (s.selector_type == "position" and s.position_id == ^position_id)
          ),
        else: dynamic([_p, s], s.selector_type == "company")

    with {:ok, _company} <- current_company(scope, company_id) do
      matches =
        Repo.all(
          from(p in Tenancy.scope_query(Profile, scope),
            join: s in ProfileSelector,
            on: s.profile_id == p.id,
            where:
              p.company_id == ^company_id and p.status in ["published", "retired"] and
                p.effective_from <= ^as_of and
                (is_nil(p.effective_to) or p.effective_to >= ^as_of),
            where: ^target,
            distinct: true,
            select: p
          )
        )

      case matches do
        [] -> {:ok, nil}
        [profile] -> {:ok, full_profile_view(scope, profile)}
        _ -> {:error, :ambiguous}
      end
    end
  end

  @doc """
  Positions a profile may target: every position that the mounted
  Organisation read exposes for the company today, up to 2,000.
  """
  def position_options(%Scope{} = scope, company_id) do
    Enum.reduce_while(1..@max_position_pages, {:ok, []}, fn page, {:ok, acc} ->
      case Workforce.positions(scope, company_id, Date.utc_today(),
             page: page,
             page_size: @position_page_size
           ) do
        {:ok, %ReadResult{} = read} ->
          case ReadResult.require_current(read) do
            {:ok, positions} ->
              acc = acc ++ Enum.map(positions, &position_option/1)

              if length(positions) < @position_page_size,
                do: {:halt, {:ok, acc}},
                else: {:cont, {:ok, acc}}

            _ ->
              {:halt, {:error, :unavailable}}
          end

        {:error, _} ->
          {:halt, {:error, :unavailable}}
      end
    end)
  end

  ## Positions

  @doc """
  The position an employee substantively holds on a day, as the mounted
  Organisation read exposes it, or `{:ok, nil}` when they hold none or no
  Organisation is mounted.
  """
  def position_of(%Scope{} = scope, company_id, employee_id, %Date{} = as_of)
      when is_integer(employee_id) do
    target = Integer.to_string(employee_id)

    Enum.reduce_while(1..@max_position_pages, {:ok, nil}, fn page, _acc ->
      case Workforce.positions(scope, company_id, as_of,
             page: page,
             page_size: @position_page_size
           ) do
        {:ok, %ReadResult{} = read} ->
          case ReadResult.require_current(read) do
            {:ok, positions} ->
              held =
                Enum.find(positions, fn position ->
                  Enum.any?(position.assignments || [], fn assignment ->
                    assignment.kind == "substantive" and
                      assignment.employee_reference.stable_id == target
                  end)
                end)

              cond do
                held -> {:halt, {:ok, String.to_integer(held.reference.stable_id)}}
                length(positions) < @position_page_size -> {:halt, {:ok, nil}}
                true -> {:cont, {:ok, nil}}
              end

            _ ->
              {:halt, {:error, :unavailable}}
          end

        {:error, :unavailable} ->
          {:halt, {:ok, nil}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  ## Company policy

  @doc "The company's assessment, priority and reminder policy values."
  defdelegate policy(scope, company_id), to: Policy, as: :get

  @doc "Stores the given policy values, each a bounded integer; others keep their value."
  defdelegate put_policy(scope, company_id, changes), to: Policy, as: :put

  ## Assessments

  @doc """
  Submits an assessment of an employee's skill by a login actor in the
  reporting line (or a company-wide holder). See `Bilimbi.People.Skills.Assessments`.
  """
  defdelegate submit_assessment(actor, company_id, attrs), to: Assessments, as: :submit

  @doc "Verifies (`:verify`) or returns (`:return`, with a note) a pending assessment."
  defdelegate review_assessment(actor, company_id, assessment_id, decision, note),
    to: Assessments,
    as: :review

  @doc "Finalizes a verified assessment and refreshes the employee's current score."
  defdelegate finalize_assessment(actor, company_id, assessment_id),
    to: Assessments,
    as: :finalize

  defdelegate list_assessments(actor, company_id, filters \\ %{}), to: Assessments, as: :list
  defdelegate assessable_employees(actor, company_id), to: Assessments, as: :assessable
  defdelegate assessment_queue(actor, company_id), to: Assessments, as: :queue

  defdelegate assessment_decisions(actor, company_id, assessment_id),
    to: Assessments,
    as: :decisions

  @doc "Scores with a gap in the actor's reach, mandatory and highest priority first."
  defdelegate gaps(actor, company_id), to: Standing

  @doc "The signed-in employee's own scores, actions and reassessment requests."
  defdelegate standing(actor, company_id), to: Standing, as: :own

  @doc "Critical skills and their holders against the company's backup minimum."
  defdelegate coverage(actor, company_id, as_of \\ Date.utc_today()), to: Standing

  ## Reassessment requests

  defdelegate request_reassessment(actor, company_id, employee_id, skill_id, reason),
    to: Reassessments,
    as: :request

  defdelegate pending_reassessments(actor, company_id), to: Reassessments, as: :pending
  defdelegate cancel_reassessment(actor, company_id, request_id), to: Reassessments, as: :cancel

  defdelegate perform_reassessment(actor, company_id, request_id, attrs),
    to: Reassessments,
    as: :perform

  ## Development actions

  defdelegate list_action_types(scope, company_id), to: Actions, as: :list_types
  defdelegate create_action_type(scope, company_id, attrs), to: Actions, as: :create_type

  defdelegate set_action_type_active(scope, company_id, type_id, active),
    to: Actions,
    as: :set_type_active

  defdelegate action_people(actor, company_id), to: Actions, as: :people
  defdelegate propose_action(actor, company_id, attrs), to: Actions, as: :propose
  defdelegate revise_action(actor, company_id, action_id, attrs), to: Actions, as: :revise
  defdelegate approve_action(actor, company_id, action_id), to: Actions, as: :approve
  defdelegate start_action(actor, company_id, action_id), to: Actions, as: :start
  defdelegate hold_action(actor, company_id, action_id, reason), to: Actions, as: :hold

  defdelegate complete_action(actor, company_id, action_id, evidence, reassessment_due_on),
    to: Actions,
    as: :complete

  defdelegate cancel_action(actor, company_id, action_id, reason), to: Actions, as: :cancel

  defdelegate link_action_reassessment(actor, company_id, action_id, assessment_id),
    to: Actions,
    as: :link_reassessment

  defdelegate comment_action(actor, company_id, action_id, comment, evidence \\ nil),
    to: Actions,
    as: :comment

  defdelegate list_actions(actor, company_id, group \\ :open), to: Actions, as: :list
  defdelegate owned_actions(actor, company_id, group \\ :open), to: Actions, as: :owned
  defdelegate action_events(actor, company_id, action_id), to: Actions, as: :events

  ## Reminders

  @doc "What is due and who would be told as of a day; writes nothing."
  defdelegate due_reminders(actor, company_id, as_of \\ Date.utc_today()),
    to: Reminders,
    as: :due

  @doc "Notifies each recipient of this period's due items once; replays send nothing twice."
  defdelegate issue_reminders(actor, company_id, as_of \\ nil), to: Reminders, as: :issue

  defdelegate retry_reminders(actor, company_id, as_of \\ nil), to: Reminders, as: :retry
  defdelegate reminder_inbox(actor, company_id, limit \\ 50), to: Reminders, as: :inbox

  @doc "Queues `issue_reminders/3` to run as the signed-in operator, who must hold the send capability now."
  def enqueue_reminders(%Scope{} = scope, company_id)
      when is_integer(company_id) and company_id > 0 do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @reminders_capability),
         {:ok, _job} <- Queue.enqueue_for(scope, ReminderWorker, %{"company_id" => company_id}) do
      :ok
    end
  end

  def enqueue_reminders(%Scope{}, _company_id), do: {:error, :invalid_reminders}

  ## Private

  defp current_company(scope, company_id) do
    with {:ok, read} <- Workforce.company(scope, company_id),
         do: ReadResult.require_current(read)
  end

  defp lock_company(scope, company_id) do
    case Company.lock_live_company(scope, company_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp get(schema, scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.id == ^id
        )
      )

  defp get(_schema, _scope, _company_id, _id), do: nil

  defp lock(schema, scope, company_id, id) when is_integer(id),
    do:
      Repo.one(
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.id == ^id,
          lock: "FOR UPDATE"
        )
      )

  defp lock(_schema, _scope, _company_id, _id), do: nil

  defp lock_draft(schema, scope, company_id, id) do
    case lock(schema, scope, company_id, id) do
      nil -> Repo.rollback(:not_found)
      %{status: "draft"} = record -> record
      _ -> Repo.rollback(:not_draft)
    end
  end

  defp code_exists?(schema, scope, company_id, code) when is_binary(code) do
    code = String.trim(code)

    Repo.exists?(
      from(r in Tenancy.scope_query(schema, scope),
        where: r.company_id == ^company_id and r.code == ^code
      )
    )
  end

  defp code_exists?(_schema, _scope, _company_id, _code), do: false

  defp open_draft?(schema, scope, company_id, code),
    do:
      Repo.exists?(
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.code == ^code and r.status == "draft"
        )
      )

  defp next_version(schema, scope, company_id, code) do
    (Repo.one(
       from(r in Tenancy.scope_query(schema, scope),
         where: r.company_id == ^company_id and r.code == ^code,
         select: max(r.version)
       )
     ) || 0) + 1
  end

  defp published(schema, scope, company_id, code),
    do:
      Repo.all(
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.code == ^code and r.status == "published",
          lock: "FOR UPDATE"
        )
      )

  defp active_skills?(scope, category_id),
    do:
      Repo.exists?(
        from(s in Tenancy.scope_query(Skill, scope),
          where: s.category_id == ^category_id and s.active
        )
      )

  defp require_active_category(scope, company_id, category_id),
    do: require_category(scope, company_id, category_id, true)

  # A category always belongs to the skill's company; an active skill also
  # needs an active category.
  defp require_category(scope, company_id, category_id, active?) do
    with {:ok, id} <- parse_integer(category_id),
         %Category{} = category <- get(Category, scope, company_id, id),
         true <- category.active or not active? do
      category
    else
      _ -> Repo.rollback(:category_unavailable)
    end
  end

  defp require_published_scale(scope, company_id, scale_id) do
    with {:ok, id} <- parse_integer(scale_id),
         %Scale{status: "published"} = scale <- get(Scale, scope, company_id, id) do
      scale
    else
      _ -> Repo.rollback(:scale_unavailable)
    end
  end

  defp levels_by_scale(_scope, []), do: %{}

  defp levels_by_scale(scope, ids) do
    Repo.all(
      from(l in Tenancy.scope_query(ScaleLevel, scope),
        where: l.scale_id in ^ids,
        order_by: [asc: l.level]
      )
    )
    |> Enum.group_by(& &1.scale_id)
  end

  defp current_scale(scope, company_id, scale_id, items) do
    source = get(Scale, scope, company_id, scale_id)

    case source && published(Scale, scope, company_id, source.code) do
      [current] ->
        levels = scale_level_numbers(scope, current.id)
        missing = items |> Enum.map(& &1.required_level) |> Enum.reject(&(&1 in levels))

        if missing == [],
          do: {current.id, []},
          else: {scale_id, missing |> Enum.uniq() |> Enum.sort()}

      _ ->
        {scale_id, []}
    end
  end

  defp scale_level_numbers(scope, scale_id),
    do: scope |> levels_by_scale([scale_id]) |> Map.get(scale_id, []) |> Enum.map(& &1.level)

  defp validate_levels(levels) do
    numbers = Enum.map(levels, & &1.level)
    names = Enum.map(levels, &String.downcase(&1.name))

    length(levels) >= 2 and numbers == Enum.to_list(0..(length(levels) - 1)) and
      length(Enum.uniq(names)) == length(names)
  end

  defp items(scope, profile_id),
    do:
      Repo.all(
        from(i in Tenancy.scope_query(ProfileItem, scope),
          where: i.profile_id == ^profile_id,
          order_by: [asc: i.sequence]
        )
      )

  defp selectors(scope, profile_id),
    do:
      Repo.all(
        from(s in Tenancy.scope_query(ProfileSelector, scope),
          where: s.profile_id == ^profile_id,
          order_by: [asc: s.id]
        )
      )

  # Two passes keep the unique sequence index satisfied while items swap places.
  defp resequence(items) do
    items = Enum.with_index(items, 1)
    for {item, index} <- items, do: set_sequence(item, -index)
    for {item, index} <- items, do: set_sequence(item, index)
  end

  defp set_sequence(item, sequence),
    do:
      Repo.update_all(from(i in ProfileItem, where: i.id == ^item.id), set: [sequence: sequence])

  defp validate_publishable(scope, company_id, profile, items, selectors) do
    scale = get(Scale, scope, company_id, profile.scale_id)
    levels = scale_level_numbers(scope, profile.scale_id)
    skills = Map.new(items, &{&1.skill_id, get(Skill, scope, company_id, &1.skill_id)})
    total = Enum.reduce(items, Decimal.new(0), &Decimal.add(&1.weight_percent, &2))

    cond do
      items == [] ->
        Repo.rollback(:no_items)

      selectors == [] ->
        Repo.rollback(:no_selectors)

      scale == nil or scale.status != "published" ->
        Repo.rollback(:scale_unavailable)

      Enum.any?(items, &(&1.required_level not in levels)) ->
        Repo.rollback(:level_not_on_scale)

      Enum.any?(Map.values(skills), &(&1 == nil or not &1.active)) ->
        Repo.rollback(:skill_unavailable)

      not Decimal.eq?(total, 100) ->
        Repo.rollback(:weights_not_100)

      true ->
        validate_positions(scope, company_id, selectors)
    end
  end

  defp validate_positions(scope, company_id, selectors) do
    wanted = for %{selector_type: "position", position_id: id} <- selectors, do: id

    if wanted == [] do
      :ok
    else
      case position_options(scope, company_id) do
        {:ok, options} ->
          known = MapSet.new(options, & &1.id)

          if Enum.all?(wanted, &MapSet.member?(known, &1)),
            do: :ok,
            else: Repo.rollback(:position_unavailable)

        {:error, _} ->
          Repo.rollback(:position_unavailable)
      end
    end
  end

  defp validate_target(_scope, _company_id, :company), do: :ok

  defp validate_target(scope, company_id, {:position, id}) when is_integer(id) do
    case position_options(scope, company_id) do
      {:ok, options} ->
        if Enum.any?(options, &(&1.id == id)), do: :ok, else: {:error, :position_unavailable}

      {:error, _} ->
        {:error, :position_unavailable}
    end
  end

  defp validate_target(_scope, _company_id, _target), do: {:error, :invalid_selector}

  defp position_id(:company), do: nil
  defp position_id({:position, id}), do: id

  # A version starts after the published version's start, which it closes, and
  # after every retired version's last day, so versions of one code never overlap.
  defp after_code_history?(scope, company_id, code, from) do
    not Repo.exists?(
      from(p in Tenancy.scope_query(Profile, scope),
        where:
          p.company_id == ^company_id and p.code == ^code and
            ((p.status == "published" and p.effective_from >= ^from) or
               (p.status == "retired" and p.effective_to >= ^from))
      )
    )
  end

  # Another code overlaps when one of its versions is published or retired on
  # or after `from` and either side targets the company or both share a position.
  defp overlapping?(scope, company_id, profile, selectors, from) do
    others =
      Repo.all(
        from(p in Tenancy.scope_query(Profile, scope),
          join: s in ProfileSelector,
          on: s.profile_id == p.id,
          where:
            p.company_id == ^company_id and p.code != ^profile.code and
              p.status in ["published", "retired"] and
              (is_nil(p.effective_to) or p.effective_to >= ^from),
          select: {s.selector_type, s.position_id}
        )
      )

    company_wide? = Enum.any?(selectors, &(&1.selector_type == "company"))
    mine = MapSet.new(selectors, & &1.position_id)

    others != [] and
      (company_wide? or
         Enum.any?(others, fn {type, position_id} ->
           type == "company" or MapSet.member?(mine, position_id)
         end))
  end

  defp position_option(position) do
    %{
      id: String.to_integer(position.reference.stable_id),
      code: position.code,
      title: position.title
    }
  end

  defp copy(record, profile_id) do
    %{record | id: nil, profile_id: profile_id, inserted_at: nil, updated_at: nil}
    |> Ecto.put_meta(state: :built)
  end

  defp transact(fun) do
    Repo.transaction(fn -> fun.() end)
  end

  defp unwrap_view({:ok, value}, view), do: view.(value)
  defp unwrap_view({:error, reason}, _view), do: Repo.rollback(reason)

  defp view_result({:ok, value}, view), do: {:ok, view.(value)}
  defp view_result(error, _view), do: error

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_number}

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_), do: {:error, :invalid_date}

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp category_view(c), do: Map.take(c, [:id, :code, :name, :description, :active])

  defp skill_view(s),
    do:
      Map.take(s, [
        :id,
        :category_id,
        :code,
        :name,
        :definition,
        :evidence_guide,
        :critical,
        :reassessment_months,
        :active
      ])

  defp scale_view(scale, levels) do
    scale
    |> Map.take([:id, :code, :name, :version, :status, :published_at, :retired_at])
    |> Map.put(:levels, Enum.map(levels, &level_view/1))
  end

  defp level_view(l), do: Map.take(l, [:level, :name, :anchor, :authority])

  defp profile_view(p),
    do:
      Map.take(p, [
        :id,
        :code,
        :name,
        :version,
        :status,
        :scale_id,
        :effective_from,
        :effective_to,
        :published_at,
        :retired_at
      ])

  defp full_profile_view(scope, profile) do
    profile
    |> profile_view()
    |> Map.merge(%{
      items: Enum.map(items(scope, profile.id), &item_view/1),
      selectors: Enum.map(selectors(scope, profile.id), &selector_view/1)
    })
  end

  defp item_view(i),
    do:
      Map.take(i, [
        :id,
        :skill_id,
        :sequence,
        :required_level,
        :criticality,
        :weight_percent,
        :mandatory,
        :evidence_standard
      ])

  defp selector_view(s), do: Map.take(s, [:id, :selector_type, :position_id])
end
