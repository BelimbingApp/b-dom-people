defmodule Bilimbi.People.Attendance.Web.Components do
  @moduledoc false
  # Company selection and the rules-area tabs shared by attendance pages.
  use Phoenix.Component

  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Attendance.ShiftTemplate

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"
  def input_class, do: @input

  @doc "Active companies the actor may act on under `capability`."
  def companies(actor, capability) do
    case Company.list_selectable_companies(actor, capability) do
      {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
      _ -> []
    end
  end

  def pick(companies, id) do
    Enum.find(companies, &(to_string(&1.id) == to_string(id))) || List.first(companies)
  end

  @doc "Formats a UTC time in the company's attendance time zone."
  def local_time(nil, _timezone), do: ""

  def local_time(%DateTime{} = at, timezone) do
    case BaseDateTime.shift(at, timezone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    end
  end

  def clock_label("in"), do: "Clock in"
  def clock_label("out"), do: "Clock out"
  def clock_label(other), do: other

  def shift_hours(template),
    do:
      "#{ShiftTemplate.clock(template.start_minute)}–#{ShiftTemplate.clock(template.end_minute)}"

  attr(:id, :string, required: true)
  attr(:companies, :list, required: true)
  attr(:company, :map, required: true)

  def company_select(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <form id={@id} phx-change="select_company">
      <label for={"#{@id}-select"} class="block text-sm font-medium text-ink-strong">Company</label>
      <select id={"#{@id}-select"} name="company_id" class={["mt-2 w-full", @input]}>
        <option :for={company <- @companies} value={company.id} selected={company.id == @company.id}>
          {company.name}
        </option>
      </select>
    </form>
    """
  end

  attr(:current, :atom, required: true)
  attr(:company, :map, default: nil)

  def rules_tabs(assigns) do
    assigns =
      assign(
        assigns,
        :query,
        if(assigns.company, do: "?company_id=#{assigns.company.id}", else: "")
      )

    ~H"""
      <Bilimbi.Base.UI.Components.tabs id="attendance-rules-tabs" aria-label="Attendance rules" class="mt-4">
        <:tab id="attendance-rules-tab" href={"/people/attendance/rules#{@query}"} current={@current == :rules}>
          Rules
        </:tab>
        <:tab id="attendance-allowances-tab" href={"/people/attendance/rules/allowances#{@query}"} current={@current == :allowances}>
          Allowance rules
        </:tab>
      <:tab id="attendance-shifts-tab" href={"/people/attendance/rules/shifts#{@query}"} current={@current == :shifts}>
        Shift templates
      </:tab>
      <:tab id="attendance-locations-tab" href={"/people/attendance/rules/locations#{@query}"} current={@current == :locations}>
        Clocking locations
      </:tab>
    </Bilimbi.Base.UI.Components.tabs>
    """
  end
end
