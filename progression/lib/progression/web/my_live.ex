defmodule Bilimbi.People.Progression.Web.MyLive do
  @moduledoc "The linked employee's progression explanation."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.People.Progression
  alias Bilimbi.People.Progression.Web.Support
  @impl true
  def mount(_, _, socket) do
    scope = socket.assigns.current_scope.scope
    company = Bilimbi.Base.Tenancy.Scope.actor(scope).company_id
    socket = assign(socket, page_title: "My progression", active_nav: nil)

    case Progression.explain(scope, company) do
      {:ok, result} -> {:ok, assign(socket, result: result, unavailable: nil)}
      {:error, reason} -> {:ok, assign(socket, result: nil, unavailable: Support.message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.header>My progression</.header>
        <.empty_state :if={@unavailable} id="my-progression-unavailable" title="Your progression explanation is unavailable" reason={@unavailable}/>
        <div :if={@result} id="my-progression" class="space-y-4">
          <.card :for={e <- @result.explanations} id={"my-progression-#{e.policy.id}"} inner_class="p-5 sm:p-6">
            <.section_heading title={e.policy.name}/>
            <.list>
              <:item title="Policy version">{e.policy.code} · {e.policy.version}</:item>
              <:item title="Effective from">{e.policy.effective_from}</:item>
              <:item title="Eligibility criteria">{label(e.status)}</:item>
            </.list>
            <.table id={"progression-explanation-#{e.policy.id}"} rows={e.rules} framed={false}>
              <:col :let={r} label="Criterion">{r.code}</:col>
              <:col :let={r} label="Result">{label(r.status)}</:col>
              <:col :let={r} label="Evidence">
                <span :if={r.source == :skill}>Required level {r.required_level} · {if r.observed_level != nil, do: "observed #{r.observed_level}", else: "current assessment unavailable"}</span>
                <span :if={r.source == :performance && r.review_id}>Released review {r.review_id} · version {r.review_version} · {r.period_start} – {r.period_end}{if r.supersedes_id, do: " · corrected evidence requires reevaluation", else: ""}</span>
                <span :if={r.source == :performance && !r.review_id}>No released review in the policy's declared period.</span>
              </:col>
            </.table>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp label(:met), do: "Met"
  defp label(:not_met), do: "Not met"
  defp label(:unknown), do: "Unknown"
end
