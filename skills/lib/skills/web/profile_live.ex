defmodule Bilimbi.People.Skills.Web.ProfileLive do
  @moduledoc "One requirement profile version: draft editing, publication and retirement."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.ProfileItem

  @capability "people.skills.catalog.view"
  @manage_capability "people.skills.catalog.manage"
  @write_events ~w(put_item remove_item move_item add_selector remove_selector new_version
                   discard move_scale)
  @decision_events ~w(publish retire)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Requirement profile")
     |> assign(:active_nav, "people.development.skills")
     |> assign(:criticalities, ProfileItem.criticalities())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope.scope

    with {company_id, ""} <- Integer.parse(Map.get(params, "company_id", "")),
         {profile_id, ""} <- Integer.parse(Map.get(params, "id", "")),
         {:ok, company} <- Authorization.authorize_company(scope, company_id, @capability) do
      {:noreply,
       socket
       |> assign(:company, company)
       |> assign(:profile_id, profile_id)
       |> assign(:can_manage?, allowed?(scope, company_id, @manage_capability))
       |> assign(:can_publish?, allowed?(scope, company_id, Skills.publish_capability()))
       |> load()}
    else
      _ ->
        {:noreply,
         assign(socket, company: nil, profile: nil, can_manage?: false, can_publish?: false)}
    end
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's skills.")}

  def handle_event(event, _params, %{assigns: %{can_publish?: false}} = socket)
      when event in @decision_events,
      do: {:noreply, put_flash(socket, :error, error_message(:unauthorized))}

  def handle_event("put_item", %{"item" => attrs}, socket) do
    attrs = Map.put(attrs, "mandatory", Map.get(attrs, "mandatory") == "true")

    draft(socket, "Requirement saved.", fn scope, company_id, id ->
      Skills.put_item(scope, company_id, id, attrs)
    end)
  end

  def handle_event("remove_item", %{"id" => item_id}, socket) do
    draft(socket, "Requirement removed.", fn scope, company_id, id ->
      Skills.remove_item(scope, company_id, id, to_integer(item_id))
    end)
  end

  def handle_event("move_item", %{"id" => item_id, "direction" => direction}, socket) do
    direction = if direction == "up", do: :up, else: :down

    draft(socket, "Requirement moved.", fn scope, company_id, id ->
      Skills.move_item(scope, company_id, id, to_integer(item_id), direction)
    end)
  end

  def handle_event("add_selector", %{"selector" => %{"target" => target}}, socket) do
    target =
      case target do
        "company" -> :company
        value -> {:position, to_integer(value)}
      end

    draft(socket, "Target added.", fn scope, company_id, id ->
      Skills.add_selector(scope, company_id, id, target)
    end)
  end

  def handle_event("remove_selector", %{"id" => selector_id}, socket) do
    draft(socket, "Target removed.", fn scope, company_id, id ->
      Skills.remove_selector(scope, company_id, id, to_integer(selector_id))
    end)
  end

  def handle_event("move_scale", %{"scale_id" => scale_id}, socket) do
    draft(socket, "Scale changed.", fn scope, company_id, id ->
      Skills.update_profile(scope, company_id, id, %{scale_id: scale_id})
    end)
  end

  def handle_event("new_version", _params, socket) do
    draft(socket, "New draft version added.", fn scope, company_id, id ->
      with {:ok, draft} <- Skills.new_profile_version(scope, company_id, id) do
        send(self(), {:open, draft.id, draft.missing_levels})
        {:ok, draft}
      end
    end)
  end

  def handle_event("discard", _params, socket) do
    company = socket.assigns.company

    case draft(socket, "Draft discarded.", fn scope, company_id, id ->
           Skills.discard_profile(scope, company_id, id)
         end) do
      {:noreply, %{assigns: %{flash: %{"success" => _}}} = socket} ->
        {:noreply, push_navigate(socket, to: ~p"/people/skills?company_id=#{company.id}")}

      other ->
        other
    end
  end

  def handle_event("publish", %{"effective_from" => date}, socket) do
    decide(socket, "Profile published.", fn scope, company_id, id ->
      Skills.publish_profile(scope, company_id, id, date)
    end)
  end

  def handle_event("retire", %{"effective_to" => date}, socket) do
    decide(socket, "Profile retired.", fn scope, company_id, id ->
      Skills.retire_profile(scope, company_id, id, date)
    end)
  end

  @impl true
  def handle_info({:open, id, missing_levels}, socket) do
    socket =
      if missing_levels == [],
        do: socket,
        else:
          put_flash(
            socket,
            :error,
            "The current scale version lacks required levels #{Enum.join(missing_levels, ", ")}; " <>
              "the draft keeps its previous scale until those requirements change."
          )

    {:noreply,
     push_patch(socket,
       to: ~p"/people/skills/profiles/#{id}?company_id=#{socket.assigns.company.id}"
     )}
  end

  defp draft(socket, success, fun) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    if allowed?(scope, company_id, @capability) and
         allowed?(scope, company_id, @manage_capability),
       do: respond(socket, success, fun.(scope, company_id, socket.assigns.profile_id)),
       else: {:noreply, put_flash(socket, :error, "You cannot change this company's skills.")}
  end

  # The facade authorizes the publish capability for the scope's actor now;
  # the `can_publish?` assign only decides whether the form renders.
  defp decide(socket, success, fun) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    if allowed?(scope, company_id, @capability) and
         allowed?(scope, company_id, Skills.publish_capability()) do
      respond(
        socket,
        success,
        fun.(scope, company_id, socket.assigns.profile_id)
      )
    else
      respond(socket, success, {:error, :unauthorized})
    end
  end

  defp respond(socket, success, {:ok, _}),
    do: {:noreply, socket |> load() |> put_flash(:success, success)}

  defp respond(socket, _success, {:error, reason}),
    do: {:noreply, put_flash(socket, :error, error_message(reason))}

  defp error_message(:unauthorized), do: "You cannot publish or retire this company's profiles."
  defp error_message(:no_items), do: "Add at least one skill requirement."
  defp error_message(:no_selectors), do: "Target the company or at least one position."
  defp error_message(:weights_not_100), do: "Requirement weights must total 100."

  defp error_message(:level_not_on_scale),
    do: "Each required level must exist on the scale; change those requirements first."

  defp error_message(:skill_unavailable), do: "Every skill must be active in this company."
  defp error_message(:scale_unavailable), do: "The profile's scale is no longer published."

  defp error_message(:position_unavailable),
    do: "That position is not available from Organisation."

  defp error_message(:mixed_selectors),
    do: "A profile targets the whole company or positions, not both."

  defp error_message(:duplicate_selector), do: "That target is already listed."

  defp error_message(:not_after_latest),
    do: "The new version must start after the current version's start date."

  defp error_message(:overlapping_profile),
    do: "Another requirement profile already targets some of these employees from that date."

  defp error_message(:draft_exists), do: "This profile already has an open draft."
  defp error_message(:invalid_date), do: "Choose a valid date on or after the version's start."
  defp error_message(_), do: "The requirement profile could not be changed."

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id

    with {:ok, profile} <- Skills.get_profile(scope, company_id, socket.assigns.profile_id),
         {:ok, skills} <- Skills.list_skills(scope, company_id),
         {:ok, scales} <- Skills.list_scales(scope, company_id) do
      scale = Enum.find(scales, &(&1.id == profile.scale_id))

      positions =
        with true <- profile.status == "draft" or profile.selectors != [],
             {:ok, options} <- Skills.position_options(scope, company_id) do
          options
        else
          _ -> []
        end

      assign(socket,
        profile: profile,
        skills: skills,
        scale: scale,
        published_scales: Enum.filter(scales, &(&1.status == "published")),
        positions: positions,
        total_weight:
          Enum.reduce(profile.items, Decimal.new(0), &Decimal.add(&1.weight_percent, &2))
      )
    else
      _ -> assign(socket, :profile, nil)
    end
  end

  defp allowed?(scope, company_id, capability),
    do: match?({:ok, _}, Authorization.authorize_company(scope, company_id, capability))

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_integer(_), do: nil

  defp skill_name(skills, id), do: Enum.find_value(skills, "", &(&1.id == id && &1.name))

  defp level_name(nil, level), do: to_string(level)

  defp level_name(scale, level),
    do:
      Enum.find_value(
        scale.levels,
        to_string(level),
        &(&1.level == level && "#{level} · #{&1.name}")
      )

  defp target_label(%{selector_type: "company"}, _positions), do: "Whole company"

  defp target_label(%{position_id: id}, positions) do
    case Enum.find(positions, &(&1.id == id)) do
      nil -> "Position ##{id}"
      position -> "#{position.title || position.code} (#{position.code})"
    end
  end

  defp input_class, do: "rounded-md border border-line bg-surface px-3 py-2 text-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="skill-profile-page">
        <.empty_state :if={@profile == nil} id="skill-profile-missing"
          title="This requirement profile is not available." />
        <div :if={@profile}>
          <.header>
            {@profile.name}
            <:subtitle>
              {@company.name} · {@profile.code} · version {@profile.version} · {@profile.status}
              <span :if={@profile.effective_from}>
                · effective {@profile.effective_from} – {@profile.effective_to || "open"}
              </span>
            </:subtitle>
          </.header>
          <p class="text-sm">
            <.link navigate={~p"/people/skills?company_id=#{@company.id}"} class="underline">Back to skills</.link>
            <span :if={@scale}> · Scale: {@scale.name} v{@scale.version} ({@scale.status})</span>
          </p>
          <form :if={@can_manage? and @profile.status == "draft" and @published_scales != []}
            id="skill-profile-scale-form" phx-submit="move_scale" class="mt-3 flex flex-wrap items-end gap-2">
            <select name="scale_id" aria-label="Scale" class={input_class()}>
              <option :for={scale <- @published_scales} value={scale.id} selected={scale.id == @profile.scale_id}>
                {scale.name} ({scale.code}) v{scale.version}
              </option>
            </select>
            <.button type="submit">Change scale</.button>
          </form>

          <section class="mt-5 rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Skill requirements</h2>
            <p :if={@profile.items == []} id="skill-profile-items-empty" class="mt-3 text-sm text-ink-muted">
              No skill requirements have been added.
            </p>
            <.table :if={@profile.items != []} id="skill-profile-items" rows={@profile.items}
              row_id={&"skill-profile-item-#{&1.id}"}>
              <:col :let={item} label="#" align={:right}>{item.sequence}</:col>
              <:col :let={item} label="Skill">{skill_name(@skills, item.skill_id)}</:col>
              <:col :let={item} label="Required level">{level_name(@scale, item.required_level)}</:col>
              <:col :let={item} label="Criticality">{item.criticality}</:col>
              <:col :let={item} label="Weight %" align={:right}>{item.weight_percent}</:col>
              <:col :let={item} label="Mandatory">{if item.mandatory, do: "Yes", else: "No"}</:col>
              <:col :let={item} :if={@can_manage? and @profile.status == "draft"} label="">
                <span class="flex gap-2">
                  <button type="button" class="underline" phx-click="move_item" phx-value-id={item.id}
                    phx-value-direction="up">Up</button>
                  <button type="button" class="underline" phx-click="move_item" phx-value-id={item.id}
                    phx-value-direction="down">Down</button>
                  <button type="button" class="underline" phx-click="remove_item" phx-value-id={item.id}>Remove</button>
                </span>
              </:col>
            </.table>
            <p id="skill-profile-total" class="mt-2 text-sm text-ink-muted">
              Total weight {@total_weight}% of 100%.
            </p>
            <form :if={@can_manage? and @profile.status == "draft" and @scale} id="skill-profile-item-form"
              phx-submit="put_item" class="mt-4 grid gap-2 sm:grid-cols-3">
              <select name="item[skill_id]" aria-label="Skill" class={input_class()}>
                <option :for={skill <- @skills} :if={skill.active} value={skill.id}>{skill.name}</option>
              </select>
              <select name="item[required_level]" aria-label="Required level" class={input_class()}>
                <option :for={level <- @scale.levels} value={level.level}>{level.level} · {level.name}</option>
              </select>
              <select name="item[criticality]" aria-label="Criticality" class={input_class()}>
                <option :for={value <- @criticalities} value={value}>{value}</option>
              </select>
              <input name="item[weight_percent]" aria-label="Weight percent" placeholder="Weight %"
                inputmode="decimal" required class={input_class()} />
              <input name="item[evidence_standard]" aria-label="Evidence standard" placeholder="Evidence standard"
                maxlength="2000" class={input_class()} />
              <label class="flex items-center gap-2 text-sm">
                <input type="checkbox" name="item[mandatory]" value="true" />Mandatory
              </label>
              <.button type="submit">Save requirement</.button>
            </form>
          </section>

          <section class="mt-5 rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Applies to</h2>
            <p :if={@profile.selectors == []} id="skill-profile-selectors-empty" class="mt-3 text-sm text-ink-muted">
              No target has been chosen.
            </p>
            <ul :if={@profile.selectors != []} id="skill-profile-selectors" class="mt-3 divide-y divide-line text-sm">
              <li :for={selector <- @profile.selectors} class="flex items-center gap-2 py-2">
                {target_label(selector, @positions)}
                <button :if={@can_manage? and @profile.status == "draft"} type="button"
                  class="ml-auto underline" phx-click="remove_selector" phx-value-id={selector.id}>Remove</button>
              </li>
            </ul>
            <form :if={@can_manage? and @profile.status == "draft"} id="skill-profile-selector-form"
              phx-submit="add_selector" class="mt-4 flex flex-wrap items-end gap-2">
              <select name="selector[target]" aria-label="Target" class={input_class()}>
                <option value="company">Whole company</option>
                <option :for={position <- @positions} value={position.id}>
                  {position.title || position.code} ({position.code})
                </option>
              </select>
              <.button type="submit">Add target</.button>
            </form>
          </section>

          <section :if={@profile.status != "retired"} class="mt-5 rounded-xl border border-line bg-surface p-5">
            <h2 class="text-base font-semibold text-ink">Version</h2>
            <form :if={@can_publish? and @profile.status == "draft"} id="skill-profile-publish-form"
              phx-submit="publish" class="mt-3 flex flex-wrap items-end gap-2">
              <label for="skill-profile-effective-from" class="text-sm">Effective from</label>
              <input id="skill-profile-effective-from" type="date" name="effective_from" required class={input_class()} />
              <.button type="submit">Publish</.button>
            </form>
            <form :if={@can_publish? and @profile.status == "published"} id="skill-profile-retire-form"
              phx-submit="retire" class="mt-3 flex flex-wrap items-end gap-2">
              <label for="skill-profile-effective-to" class="text-sm">Last effective day</label>
              <input id="skill-profile-effective-to" type="date" name="effective_to" required class={input_class()} />
              <.button type="submit">Retire</.button>
            </form>
            <div :if={@can_manage?} class="mt-3 flex gap-3 text-sm">
              <button :if={@profile.status == "published"} id="skill-profile-new-version" type="button"
                class="underline" phx-click="new_version">Draft a new version</button>
              <button :if={@profile.status == "draft"} id="skill-profile-discard" type="button"
                class="underline" phx-click="discard">Discard draft</button>
            </div>
            <p :if={not @can_publish? and @profile.status == "draft"} class="mt-3 text-sm text-ink-muted">
              Publishing needs the requirement publisher capability for this company.
            </p>
          </section>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
