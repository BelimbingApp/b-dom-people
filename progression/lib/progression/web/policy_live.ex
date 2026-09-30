defmodule Bilimbi.People.Progression.Web.PolicyLive do
  @moduledoc "Progression policy history and governed publication."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.{Progression, Skills}
  alias Bilimbi.People.Progression.Web.Support
  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         page_title: "Progression policies",
         active_nav: nil,
         pending: nil,
         selected: nil,
         error: nil
       )}

  @impl true
  def handle_params(params, _, socket) do
    socket =
      assign(socket,
        page: Support.integer(params["page"]) || 1,
        page_size:
          if(Support.integer(params["page_size"]) in [10, 25, 50, 100],
            do: Support.integer(params["page_size"]),
            else: 25
          )
      )

    {:noreply, load(socket)}
  end

  @impl true
  def handle_event(event, _, %{assigns: %{can_manage?: false}} = socket)
      when event in ["draft", "request_publish", "confirm_publish"],
      do: {:noreply, assign(socket, :error, Support.message(:unauthorized))}

  def handle_event("draft", %{"policy" => attrs}, socket) do
    scope = socket.assigns.current_scope.scope
    company = Bilimbi.Base.Tenancy.Scope.actor(scope).company_id

    result =
      with {:ok, rules} <- rules(scope, company, attrs) do
        Progression.draft(
          scope,
          company,
          Map.take(attrs, ~w(code version name effective_from)) |> Map.put("rules", rules)
        )
      end

    finish(
      assign(socket, :policy_form, to_form(attrs, as: :policy)),
      result,
      "Policy draft recorded."
    )
  end

  def handle_event("request_publish", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.id == Support.integer(id) and &1.status == "draft"))
    {:noreply, assign(socket, :pending, row)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.id == Support.integer(id)))
    {:noreply, assign(socket, :selected, row)}
  end

  def handle_event("clear_error", _, socket), do: {:noreply, assign(socket, :error, nil)}

  def handle_event("cancel_publish", _, socket), do: {:noreply, assign(socket, :pending, nil)}

  def handle_event("confirm_publish", _, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_publish", _, socket) do
    scope = socket.assigns.current_scope.scope

    result =
      Progression.publish(
        scope,
        Bilimbi.Base.Tenancy.Scope.actor(scope).company_id,
        socket.assigns.pending.id
      )

    finish(assign(socket, :pending, nil), result, "Policy published.")
  end

  def handle_event("filter", %{"filters" => params}, socket),
    do: handle_event("paginate", Map.put(params, "page", "1"), socket)

  def handle_event("paginate", params, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           "/people/progression?" <>
             URI.encode_query(%{
               page: params["page"] || 1,
               page_size: params["perPage"] || socket.assigns.page_size
             })
       )}

  defp finish(socket, {:ok, _}, message),
    do: {:noreply, socket |> assign(:error, nil) |> put_flash(:success, message) |> load()}

  defp finish(socket, {:error, reason}, _),
    do: {:noreply, assign(socket, :error, Support.message(reason))}

  defp rules(scope, company, attrs) do
    competence =
      case Support.integer(attrs["profile_id"]) do
        nil ->
          {:ok, []}

        id ->
          with {:ok, p} <- Skills.get_profile(scope, company, id),
               true <- p.status == "published" and p.items != [],
               {:ok, skills} <- Skills.list_skills(scope, company) do
            codes = Map.new(skills, &{&1.id, &1.code})

            {:ok,
             Enum.map(
               p.items,
               &%{
                 "code" => codes[&1.skill_id],
                 "skill_id" => &1.skill_id,
                 "required_level" => &1.required_level,
                 "profile_id" => p.id,
                 "profile_version" => p.version
               }
             )}
          else
            _ -> {:error, :profile_unavailable}
          end
      end

    with {:ok, competence} <- competence do
      performance =
        if attrs["performance"] == "true",
          do: %{
            "periods" => [%{"start" => attrs["period_start"], "end" => attrs["period_end"]}],
            "accepted_outcomes" =>
              String.split(attrs["outcomes"] || "", ",", trim: true) |> Enum.map(&String.trim/1),
            "missing_evidence" => attrs["missing_evidence"]
          },
          else: nil

      {:ok, %{"competence" => competence, "performance" => performance}}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope.scope
    company = Bilimbi.Base.Tenancy.Scope.actor(scope).company_id
    can? = Progression.allowed?(scope, company, "people.progression.policy.manage")

    profiles =
      if can? do
        case Skills.list_profiles(scope, company) do
          {:ok, rows} -> Enum.filter(rows, &(&1.status == "published"))
          _ -> []
        end
      else
        []
      end

    socket =
      assign(socket,
        can_manage?: can?,
        profiles: profiles,
        filter_form: to_form(%{"perPage" => to_string(socket.assigns.page_size)}, as: :filters),
        policy_form:
          to_form(%{"missing_evidence" => "unknown", "performance" => "false"}, as: :policy)
      )

    case Progression.policies(scope, company,
           page: socket.assigns.page,
           page_size: socket.assigns.page_size
         ) do
      {:ok, result} ->
        assign(socket,
          rows: result.rows,
          total: result.total,
          page: result.page,
          unavailable: nil
        )

      {:error, reason} ->
        assign(socket, rows: [], total: 0, unavailable: Support.message(reason))
    end
  end

  attr(:policy, :map, required: true)

  defp criteria(assigns) do
    ~H"""
    <.table rows={@policy.rules["competence"]} id={"policy-criteria-#{@policy.id}"}>
      <:col :let={r} label="Skill criterion">{r["code"]}</:col>
      <:col :let={r} label="Required level">{r["required_level"]}</:col>
      <:col :let={r} label="Profile version">{r["profile_id"]} · {r["profile_version"]}</:col>
      <:empty :if={@policy.rules["competence"] == []}><.empty_state title="No skill criteria" reason="This policy declares performance criteria only."/></:empty>
    </.table>
    <.list :if={@policy.rules["performance"]}>
      <:item title="Performance periods"><span :for={p <- @policy.rules["performance"]["periods"]} class="block">{p["start"]} – {p["end"]}</span></:item>
      <:item title="Accepted outcomes">{Enum.join(@policy.rules["performance"]["accepted_outcomes"], ", ")}</:item>
      <:item title="Missing released evidence">{@policy.rules["performance"]["missing_evidence"]}</:item>
    </.list>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>Progression policies</.header>
        <p class="text-sm text-muted">Published criteria explain eligibility. They do not authorize a promotion or change pay.</p>
        <.panel_notice :if={@error} id="progression-error" kind={:error} on_dismiss={JS.push("clear_error")}>{@error}</.panel_notice>
        <.empty_state :if={@unavailable} id="progression-unavailable" title="Policies unavailable" reason={@unavailable}/>
        <.table :if={!@unavailable} id="progression-policies" rows={@rows} row_id={&"policy-#{&1.id}"}>
          <:col :let={p} label="Policy">{p.name} · {p.code}</:col>
          <:col :let={p} label="Version">{p.version}</:col>
          <:col :let={p} label="Effective from">{p.effective_from}</:col>
          <:col :let={p} label="Status">{p.status}</:col>
          <:col :let={p} label="Criteria">{length(p.rules["competence"])} skill requirements{if p.rules["performance"], do: "; performance required", else: ""}</:col>
          <:action :let={p}><.button phx-click="select" phx-value-id={p.id}>Read</.button><.button :if={@can_manage? && p.status == "draft"} phx-click="request_publish" phx-value-id={p.id}>Publish</.button></:action>
          <:empty :if={@rows == []}><.empty_state id="progression-empty" title="No progression policies" reason="An authorized policy operator must draft and publish company criteria."/></:empty>
        </.table>
        <.pagination :if={!@unavailable} id="progression-pagination" page={%{page: @page, page_size: @page_size, total_entries: @total, total_pages: ceil(@total / @page_size)}} filters_form={@filter_form} filters_event="filter" page_event="paginate" page_sizes={[10,25,50,100]}/>
        <.card :if={@selected} id="progression-detail" inner_class="p-5 sm:p-6">
          <.section_heading title={@selected.name}/>
          <.list>
            <:item title="Version">{@selected.code} · {@selected.version}</:item>
            <:item title="Effective from">{@selected.effective_from}</:item>
            <:item title="Publication"><span :if={!@selected.published_at}>Draft</span><.datetime :if={@selected.published_at} id="progression-publication-time" value={@selected.published_at}/></:item>
          </.list>
          <.criteria policy={@selected}/>
        </.card>
        <.card :if={@pending} id="progression-confirm" inner_class="p-5 sm:p-6">
          <.section_heading title="Confirm publication"/>
          <p class="text-sm">Publish {@pending.name} version {@pending.version}, effective {@pending.effective_from}? This version and its criteria become permanent. The latest effective publication will apply to employees.</p>
          <.criteria policy={@pending}/>
          <.button phx-click="confirm_publish">Confirm publication</.button>
          <.button phx-click="cancel_publish" variant="primary">Cancel</.button>
        </.card>
        <.empty_state :if={!@can_manage?} id="progression-read-only" title="Policy history is read-only" reason="A policy operator with manage permission can create and publish versions."/>
        <.page :if={@can_manage? && !@unavailable} variant={:form}>
          <.section_heading title="Draft a policy version"/>
          <.form for={@policy_form} id="progression-draft" phx-submit="draft">
            <.input field={@policy_form[:code]} label="Policy code" required/>
            <.input field={@policy_form[:name]} label="Policy name" required/>
            <.input field={@policy_form[:version]} type="number" min="1" label="Version" required/>
            <.input field={@policy_form[:effective_from]} type="date" label="Effective from" required/>
            <.input field={@policy_form[:profile_id]} type="select" label="Published competency profile" prompt="No competency criteria" options={Enum.map(@profiles, &{"#{&1.name} · version #{&1.version}", &1.id})}/>
            <.input field={@policy_form[:performance]} type="checkbox" label="Require released performance evidence"/>
            <.input field={@policy_form[:period_start]} type="date" label="Performance period start"/>
            <.input field={@policy_form[:period_end]} type="date" label="Performance period end"/>
            <.input field={@policy_form[:outcomes]} label="Accepted performance outcomes (separated by commas)"/>
            <.input field={@policy_form[:missing_evidence]} type="select" label="Missing performance evidence" options={[{"Unknown", "unknown"}, {"Not met", "not_met"}]}/>
            <.button phx-disable-with="Recording…">Record draft</.button>
          </.form>
        </.page>
      </.page>
    </Layouts.app>
    """
  end
end
