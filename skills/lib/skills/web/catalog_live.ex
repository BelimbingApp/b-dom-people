defmodule Bilimbi.People.Skills.Web.CatalogLive do
  @moduledoc "Company skill catalog, proficiency scales and requirement profile versions."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.Skills

  @capability "people.skills.catalog.view"
  @manage_capability "people.skills.catalog.manage"
  @write_events ~w(create_category set_category_active create_skill set_skill_active
                   create_scale put_level delete_level scale_action create_profile)

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Skills")
     |> assign(:active_nav, "people.development.skills")
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company =
      Enum.find(socket.assigns.companies, &(Map.get(params, "company_id") == to_string(&1.id))) ||
        List.first(socket.assigns.companies)

    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's skills.")}

  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/skills?company_id=#{id}")}

  def handle_event("create_category", %{"category" => attrs}, socket) do
    manage(socket, "Category added.", "Enter a unique lowercase code and a name.", fn scope, id ->
      Skills.create_category(scope, id, attrs)
    end)
  end

  def handle_event("set_category_active", %{"id" => category_id, "active" => active}, socket) do
    manage(
      socket,
      "Category updated.",
      "Deactivate the category's active skills first.",
      fn scope, id ->
        Skills.set_category_active(scope, id, to_integer(category_id), active == "true")
      end
    )
  end

  def handle_event("create_skill", %{"skill" => attrs}, socket) do
    attrs = Map.put(attrs, "critical", Map.get(attrs, "critical") == "true")

    manage(
      socket,
      "Skill added.",
      "Choose an active category and enter a unique code, a name and a definition.",
      fn scope, id -> Skills.create_skill(scope, id, blank_to_nil(attrs)) end
    )
  end

  def handle_event("set_skill_active", %{"id" => skill_id, "active" => active}, socket) do
    manage(socket, "Skill updated.", "Reactivate the skill's category first.", fn scope, id ->
      Skills.set_skill_active(scope, id, to_integer(skill_id), active == "true")
    end)
  end

  def handle_event("create_scale", %{"scale" => attrs}, socket) do
    manage(socket, "Scale draft added.", "Enter a new lowercase code and a name.", fn scope, id ->
      Skills.create_scale(scope, id, attrs)
    end)
  end

  def handle_event("put_level", %{"level" => attrs}, socket) do
    manage(
      socket,
      "Level saved.",
      "Enter a level from 0 to 20 with a name, observable anchor and authority.",
      fn scope, id -> Skills.put_scale_level(scope, id, to_integer(attrs["scale_id"]), attrs) end
    )
  end

  def handle_event("delete_level", %{"scale" => scale_id, "level" => level}, socket) do
    manage(socket, "Level removed.", "The level could not be removed.", fn scope, id ->
      Skills.delete_scale_level(scope, id, to_integer(scale_id), to_integer(level))
    end)
  end

  def handle_event("scale_action", %{"id" => scale_id, "action" => action}, socket) do
    scale_id = to_integer(scale_id)

    {fun, success} =
      case action do
        "publish" ->
          {&Skills.publish_scale(&1, &2, scale_id, actor_user_id(socket)), "Scale published."}

        "retire" ->
          {&Skills.retire_scale(&1, &2, scale_id), "Scale retired."}

        "new_version" ->
          {&Skills.new_scale_version(&1, &2, scale_id), "New scale draft added."}

        "discard" ->
          {&Skills.discard_scale(&1, &2, scale_id), "Scale draft discarded."}
      end

    manage(socket, success, &scale_error/1, fun)
  end

  def handle_event("create_profile", %{"profile" => attrs}, socket) do
    manage(
      socket,
      "Requirement profile draft added.",
      "Enter a new lowercase code, a name and a published scale.",
      fn scope, id -> Skills.create_profile(scope, id, attrs) end
    )
  end

  defp manage(socket, success, failure, fun) do
    actor = socket.assigns.current_scope.actor

    with %{id: company_id} <- socket.assigns.company,
         {:ok, _} <- Company.authorize_company_target(actor, company_id, @manage_capability) do
      case fun.(socket.assigns.current_scope.scope, company_id) do
        {:ok, _} ->
          {:noreply, socket |> load() |> put_flash(:success, success)}

        {:error, reason} ->
          message = if is_function(failure), do: failure.(reason), else: failure
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot change this company's skills.")}
    end
  end

  defp scale_error(:invalid_levels),
    do: "A scale needs at least two levels numbered from 0 without gaps and with distinct names."

  defp scale_error(:draft_exists), do: "That scale already has an open draft."
  defp scale_error(:scale_in_use), do: "A requirement profile uses this draft."
  defp scale_error(_), do: "The scale could not be changed."

  defp load(%{assigns: %{company: nil}} = socket), do: assign_empty(socket)

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    with {:ok, categories} <- Skills.list_categories(scope, company_id),
         {:ok, skills} <- Skills.list_skills(scope, company_id),
         {:ok, scales} <- Skills.list_scales(scope, company_id),
         {:ok, profiles} <- Skills.list_profiles(scope, company_id) do
      assign(socket,
        available?: true,
        can_manage?:
          match?(
            {:ok, _},
            Company.authorize_company_target(
              socket.assigns.current_scope.actor,
              company_id,
              @manage_capability
            )
          ),
        categories: categories,
        skills: skills,
        scales: scales,
        profiles: profiles
      )
    else
      _ -> assign_empty(socket)
    end
  end

  defp assign_empty(socket),
    do:
      assign(socket,
        available?: false,
        can_manage?: false,
        categories: [],
        skills: [],
        scales: [],
        profiles: []
      )

  defp actor_user_id(socket) do
    case socket.assigns.current_scope.actor do
      %{type: :user, id: id} -> id
      _ -> nil
    end
  end

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_integer(_), do: nil

  defp blank_to_nil(attrs),
    do: Map.new(attrs, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)

  defp category_name(categories, id),
    do: Enum.find_value(categories, "", &(&1.id == id && &1.name))

  defp scale_label(scales, id),
    do: Enum.find_value(scales, "", &(&1.id == id && "#{&1.name} v#{&1.version}"))

  defp input_class, do: "rounded-md border border-line bg-surface px-3 py-2 text-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="skills-page">
        <.header>
          Skills
          <:subtitle :if={@company}>{@company.name} · Catalog, proficiency scales and requirement profiles</:subtitle>
        </.header>
        <.empty_state :if={@company == nil} id="skills-no-company"
          title="No active company is available for skills." />
        <form :if={@company} phx-change="select_company" id="skills-company-form">
          <label for="skills-company">Company</label>
          <select id="skills-company" name="company_id">
            <option :for={company <- @companies} value={company.id}
              selected={company.id == @company.id}>{company.name}</option>
          </select>
        </form>
        <.empty_state :if={@company && not @available?} id="skills-unavailable"
          title="Skills are unavailable while this company's workforce is not current." />

        <div :if={@available?} class="mt-5 grid gap-5 lg:grid-cols-2">
          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Categories</h2>
            <p :if={@categories == []} id="skill-categories-empty" class="mt-3 text-sm text-ink-muted">
              No skill categories have been added for this company.
            </p>
            <ul :if={@categories != []} id="skill-categories" class="mt-3 divide-y divide-line text-sm">
              <li :for={category <- @categories} id={"skill-category-#{category.id}"}
                class="flex items-center gap-2 py-2">
                <span class="font-medium">{category.name}</span>
                <span class="text-ink-muted">{category.code}</span>
                <span :if={not category.active} class="text-ink-muted">· inactive</span>
                <button :if={@can_manage?} type="button" class="ml-auto text-sm underline"
                  phx-click="set_category_active" phx-value-id={category.id}
                  phx-value-active={to_string(not category.active)}>
                  {if category.active, do: "Deactivate", else: "Reactivate"}
                </button>
              </li>
            </ul>
            <form :if={@can_manage?} id="skill-category-form" phx-submit="create_category"
              class="mt-4 grid gap-2 sm:grid-cols-2">
              <input name="category[code]" aria-label="Category code" placeholder="Code" required
                maxlength="80" class={input_class()} />
              <input name="category[name]" aria-label="Category name" placeholder="Name" required
                maxlength="160" class={input_class()} />
              <input name="category[description]" aria-label="Category description"
                placeholder="Description" maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <.button type="submit">Add category</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Proficiency scales</h2>
            <p :if={@scales == []} id="skill-scales-empty" class="mt-3 text-sm text-ink-muted">
              No proficiency scales have been added. A requirement profile needs a published scale.
            </p>
            <div :for={scale <- @scales} id={"skill-scale-#{scale.id}"} class="mt-3 border-t border-line pt-3 text-sm">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{scale.name}</span>
                <span class="text-ink-muted">{scale.code} · v{scale.version} · {scale.status}</span>
                <span :if={@can_manage?} class="ml-auto flex gap-3">
                  <button :if={scale.status == "draft"} type="button" class="underline"
                    phx-click="scale_action" phx-value-id={scale.id} phx-value-action="publish">Publish</button>
                  <button :if={scale.status == "draft"} type="button" class="underline"
                    phx-click="scale_action" phx-value-id={scale.id} phx-value-action="discard">Discard</button>
                  <button :if={scale.status == "published"} type="button" class="underline"
                    phx-click="scale_action" phx-value-id={scale.id} phx-value-action="new_version">New version</button>
                  <button :if={scale.status == "published"} type="button" class="underline"
                    phx-click="scale_action" phx-value-id={scale.id} phx-value-action="retire">Retire</button>
                </span>
              </div>
              <ol class="mt-2 space-y-1">
                <li :for={level <- scale.levels} class="flex gap-2">
                  <span class="w-6 text-right tabular-nums">{level.level}</span>
                  <span><span class="font-medium">{level.name}</span> — {level.anchor}
                    <span class="text-ink-muted">Authority: {level.authority}</span></span>
                  <button :if={@can_manage? and scale.status == "draft"} type="button"
                    class="ml-auto underline" phx-click="delete_level" phx-value-scale={scale.id}
                    phx-value-level={level.level}>Remove</button>
                </li>
              </ol>
              <form :if={@can_manage? and scale.status == "draft"} id={"skill-level-form-#{scale.id}"}
                phx-submit="put_level" class="mt-2 grid gap-2 sm:grid-cols-2">
                <input type="hidden" name="level[scale_id]" value={scale.id} />
                <input name="level[level]" type="number" min="0" max="20" aria-label="Level number"
                  placeholder="Level" required value={length(scale.levels)} class={input_class()} />
                <input name="level[name]" aria-label="Level name" placeholder="Name" required
                  maxlength="100" class={input_class()} />
                <input name="level[anchor]" aria-label="Observable behaviour" placeholder="Observable behaviour"
                  required maxlength="2000" class={input_class()} />
                <input name="level[authority]" aria-label="Authority granted" placeholder="Authority granted"
                  required maxlength="2000" class={input_class()} />
                <.button type="submit">Save level</.button>
              </form>
            </div>
            <form :if={@can_manage?} id="skill-scale-form" phx-submit="create_scale"
              class="mt-4 flex flex-wrap items-end gap-2">
              <input name="scale[code]" aria-label="Scale code" placeholder="Code" required maxlength="80"
                class={input_class()} />
              <input name="scale[name]" aria-label="Scale name" placeholder="Name" required maxlength="160"
                class={input_class()} />
              <.button type="submit">Add scale</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Skills</h2>
            <p :if={@skills == []} id="skills-empty" class="mt-3 text-sm text-ink-muted">
              No skills have been added.<span :if={not Enum.any?(@categories, & &1.active)}>
                Add an active category first.</span>
            </p>
            <.table :if={@skills != []} id="skills" rows={@skills} row_id={&"skill-#{&1.id}"}>
              <:col :let={skill} label="Skill">{skill.name}</:col>
              <:col :let={skill} label="Code">{skill.code}</:col>
              <:col :let={skill} label="Category">{category_name(@categories, skill.category_id)}</:col>
              <:col :let={skill} label="Critical">{if skill.critical, do: "Yes", else: "No"}</:col>
              <:col :let={skill} label="Status">{if skill.active, do: "Active", else: "Inactive"}</:col>
              <:col :let={skill} :if={@can_manage?} label="">
                <button type="button" class="underline" phx-click="set_skill_active"
                  phx-value-id={skill.id} phx-value-active={to_string(not skill.active)}>
                  {if skill.active, do: "Deactivate", else: "Reactivate"}
                </button>
              </:col>
            </.table>
            <form :if={@can_manage? and Enum.any?(@categories, & &1.active)} id="skill-form"
              phx-submit="create_skill" class="mt-4 grid gap-2 sm:grid-cols-3">
              <select name="skill[category_id]" aria-label="Skill category" class={input_class()}>
                <option :for={category <- @categories} :if={category.active} value={category.id}>{category.name}</option>
              </select>
              <input name="skill[code]" aria-label="Skill code" placeholder="Code" required maxlength="80"
                class={input_class()} />
              <input name="skill[name]" aria-label="Skill name" placeholder="Name" required maxlength="160"
                class={input_class()} />
              <input name="skill[definition]" aria-label="Skill definition" placeholder="Definition" required
                maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <input name="skill[reassessment_months]" type="number" min="1" max="120"
                aria-label="Reassess every months" placeholder="Reassess every (months)" class={input_class()} />
              <input name="skill[evidence_guide]" aria-label="Evidence guide" placeholder="Evidence guide"
                maxlength="2000" class={[input_class(), "sm:col-span-2"]} />
              <label class="flex items-center gap-2 text-sm">
                <input type="checkbox" name="skill[critical]" value="true" />Critical skill
              </label>
              <.button type="submit">Add skill</.button>
            </form>
          </section>

          <section class="rounded-xl border border-line bg-surface p-5 lg:col-span-2">
            <h2 class="text-base font-semibold text-ink">Requirement profiles</h2>
            <p :if={@profiles == []} id="skill-profiles-empty" class="mt-3 text-sm text-ink-muted">
              No requirement profiles have been added.
            </p>
            <.table :if={@profiles != []} id="skill-profiles" rows={@profiles} row_id={&"skill-profile-#{&1.id}"}>
              <:col :let={profile} label="Profile">
                <.link navigate={~p"/people/skills/profiles/#{profile.id}?company_id=#{@company.id}"}
                  class="underline">{profile.name}</.link>
              </:col>
              <:col :let={profile} label="Code">{profile.code}</:col>
              <:col :let={profile} label="Version" align={:right}>{profile.version}</:col>
              <:col :let={profile} label="Status">{profile.status}</:col>
              <:col :let={profile} label="Scale">{scale_label(@scales, profile.scale_id)}</:col>
              <:col :let={profile} label="Effective">
                {if profile.effective_from, do: "#{profile.effective_from} – #{profile.effective_to || "open"}", else: "—"}
              </:col>
            </.table>
            <form :if={@can_manage? and Enum.any?(@scales, &(&1.status == "published"))} id="skill-profile-form"
              phx-submit="create_profile" class="mt-4 flex flex-wrap items-end gap-2">
              <input name="profile[code]" aria-label="Profile code" placeholder="Code" required maxlength="80"
                class={input_class()} />
              <input name="profile[name]" aria-label="Profile name" placeholder="Name" required maxlength="160"
                class={input_class()} />
              <select name="profile[scale_id]" aria-label="Profile scale" class={input_class()}>
                <option :for={scale <- @scales} :if={scale.status == "published"} value={scale.id}>
                  {scale.name} v{scale.version}
                </option>
              </select>
              <.button type="submit">Add profile</.button>
            </form>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
