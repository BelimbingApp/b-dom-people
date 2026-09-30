defmodule Bilimbi.People.Payroll.Web.SetupLive do
  @moduledoc "Company payroll foundation editor."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Payroll

  @write_events ~w(save_settings create_classification create_item create_period create_mapping create_run lock_run)

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(
             socket.assigns.current_scope.actor,
             "people.payroll.view"
           ) do
        {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     assign(socket,
       page_title: "Payroll setup",
       companies: companies,
       company: nil,
       can_manage?: false,
       data: nil,
       sources: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company =
      Enum.find(socket.assigns.companies, &(to_string(&1.id) == params["company_id"])) ||
        List.first(socket.assigns.companies)

    {:noreply, socket |> assign(:company, company) |> load()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's payroll setup.")}

  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/payroll/setup?company_id=#{id}")}

  def handle_event("save_settings", %{"country" => country, "currencies" => currencies}, socket),
    do:
      outcome(
        socket,
        Payroll.put_settings(
          scope(socket),
          id(socket),
          country,
          String.split(currencies, [",", " "], trim: true)
        )
      )

  def handle_event("create_classification", %{"record" => attrs}, socket),
    do: outcome(socket, Payroll.create_classification(scope(socket), id(socket), attrs))

  def handle_event("create_item", %{"record" => attrs}, socket),
    do: outcome(socket, Payroll.create_item(scope(socket), id(socket), attrs))

  def handle_event("create_period", %{"record" => attrs}, socket),
    do: outcome(socket, Payroll.create_period(scope(socket), id(socket), attrs))

  def handle_event("create_mapping", %{"record" => attrs}, socket) do
    case String.split(Map.get(attrs, "source", ""), ":", parts: 2) do
      [kind, key] ->
        outcome(
          socket,
          Payroll.create_mapping(
            scope(socket),
            id(socket),
            attrs |> Map.put("source_kind", kind) |> Map.put("source_key", key)
          )
        )

      _ ->
        outcome(socket, {:error, :invalid_mapping})
    end
  end

  def handle_event("create_run", %{"period_id" => period, "currency" => currency}, socket),
    do: outcome(socket, Payroll.create_run(scope(socket), id(socket), integer(period), currency))

  def handle_event("lock_run", %{"id" => run}, socket),
    do: outcome(socket, Payroll.lock_run(scope(socket), id(socket), integer(run)))

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp id(socket), do: socket.assigns.company.id

  defp integer(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp load(%{assigns: %{company: nil}} = socket),
    do: assign(socket, can_manage?: false, data: nil, sources: [])

  defp load(socket) do
    case Payroll.setup(scope(socket), id(socket)) do
      {:ok, data} ->
        sources =
          case Payroll.sources(scope(socket), id(socket)) do
            {:ok, kinds} ->
              for {kind, rows} <- Enum.sort(kinds),
                  row <- rows,
                  do: %{
                    value: "#{kind}:#{row.key}",
                    label: "#{String.capitalize(kind)} · #{row.name}"
                  }

            _ ->
              []
          end

        assign(socket,
          data: data,
          sources: sources,
          can_manage?: Payroll.allowed?(scope(socket), id(socket), "people.payroll.manage")
        )

      _ ->
        assign(socket, company: nil, data: nil, sources: [], can_manage?: false)
    end
  end

  defp outcome(socket, {:ok, _}),
    do:
      {:noreply,
       socket |> load() |> clear_flash(:error) |> put_flash(:success, "Payroll setup saved.")}

  defp outcome(socket, {:error, reason}) do
    message =
      case reason do
        :overlapping_version ->
          "This code or source already has a version during those dates. Choose a non-overlapping period."

        :locked ->
          "This run is locked and cannot change."

        :invalid_settings ->
          "Enter a country identifier and uppercase three-letter currency codes."

        :unauthorized ->
          "You cannot change this company's payroll setup."

        :invalid_item ->
          "Choose a classification covering the item dates, an allowed currency, and an amount with at most six decimal places."

        :invalid_mapping ->
          "Choose an available Leave or Claims source and an item covering the mapping dates."

        :run_unavailable ->
          "Choose a configured country, currency and unused period."

        _ ->
          "Check required fields, date ranges and unique codes."
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people">
      <.page id="payroll-setup" variant={:list}>
        <.header>
          Payroll setup
          <:subtitle>Periods, pay items and effective-dated mappings for one company.</:subtitle>
        </.header>
        <.empty_state
          :if={@data == nil}
          id="payroll-unavailable"
          title="No company is available for payroll setup."
        />
        <div :if={@data} class="mt-5 space-y-5">
          <form id="payroll-company" phx-change="select_company" phx-submit="select_company">
            <label for="company-select">Company</label>
            <select id="company-select" name="company_id" class="rounded-md border border-line p-2">
              <option
                :for={company <- @companies}
                value={company.id}
                selected={company.id == @company.id}
              >
                {company.name}
              </option>
            </select>
          </form>
          <p :if={!@can_manage?} class="text-sm text-ink-muted">
            You can view this company's setup. A payroll operator can add records.
          </p>
          <.card inner_class="p-5">
            <.section_heading id="payroll-policy" title="Country and currencies" />
            <p class="mt-2 text-sm">
              Country: {if @data.country == "", do: "Not configured", else: @data.country} · Currencies: {Enum.join(
                @data.currencies,
                ", "
              )}
            </p>
            <p :if={@data.country == "" or @data.currencies == []} class="mt-2 text-sm text-ink-muted">
              Choose a country and allowed currencies before creating runs. No statutory rules are activated here.
            </p>
            <form
              :if={@can_manage?}
              id="payroll-settings"
              phx-submit="save_settings"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.field name="country" label="Country identifier" value={@data.country} />
              <.field
                name="currencies"
                label="Currency codes, comma separated"
                value={Enum.join(@data.currencies, ", ")}
                required={false}
              />
              <.button type="submit">Save settings</.button>
            </form>
          </.card>
          <.card inner_class="p-5">
            <.section_heading id="payroll-classifications" title="Classifications" />
            <p class="mt-2 text-sm text-ink-muted">
              Versions cannot be edited. Use bounded dates to leave room for future versions.
            </p>
            <.empty_state
              :if={@data.classifications == []}
              id="classifications-empty"
              title="No classifications yet."
            />
            <ul class="mt-3 divide-y divide-line text-sm">
              <li :for={row <- @data.classifications} class="py-2">
                {row.code} · {row.name} · {row.effective_from} to {row.effective_to || "open"}
              </li>
            </ul>
            <form
              :if={@can_manage?}
              id="classification-form"
              phx-submit="create_classification"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.catalog_fields /><.date_fields /><.button type="submit">Add classification version</.button>
            </form>
          </.card>
          <.card inner_class="p-5">
            <.section_heading id="payroll-items" title="Pay items" />
            <.empty_state :if={@data.items == []} id="items-empty" title="No pay items yet." />
            <ul class="mt-3 divide-y divide-line text-sm">
              <li :for={row <- @data.items} class="py-2">
                {row.code} · {row.name} · {Decimal.to_string(row.amount)} {row.currency} · {row.effective_from} to {row.effective_to ||
                  "open"}
              </li>
            </ul>
            <p
              :if={@data.classifications == [] or @data.currencies == []}
              class="mt-2 text-sm text-ink-muted"
            >
              Add classifications and currency settings to create pay items.
            </p>
            <form
              :if={@can_manage? and @data.classifications != [] and @data.currencies != []}
              id="item-form"
              phx-submit="create_item"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.catalog_fields />
              <.choice
                name="record[classification_id]"
                label="Classification"
                options={
                  Enum.map(@data.classifications, &{&1.id, "#{&1.name} · #{&1.effective_from}"})
                }
              />
              <.choice
                name="record[currency]"
                label="Item currency"
                options={Enum.map(@data.currencies, &{&1, &1})}
              />
              <.field name="record[amount]" label="Exact amount" />
              <.date_fields /><.button type="submit">Add pay-item version</.button>
            </form>
          </.card>
          <.card inner_class="p-5">
            <.section_heading id="payroll-periods" title="Periods" />
            <.empty_state
              :if={@data.periods == []}
              id="periods-empty"
              title="No payroll periods yet."
            />
            <ul class="mt-3 divide-y divide-line text-sm">
              <li :for={row <- @data.periods} class="py-2">
                {row.code} · {row.starts_on} to {row.ends_on} · Pay on {row.pay_on}
              </li>
            </ul>
            <form
              :if={@can_manage?}
              id="period-form"
              phx-submit="create_period"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.field name="record[code]" label="Period code" />
              <.field name="record[starts_on]" label="From" type="date" />
              <.field name="record[ends_on]" label="To" type="date" />
              <.field name="record[pay_on]" label="Pay on" type="date" />
              <.button type="submit">Add period</.button>
            </form>
          </.card>
          <.card inner_class="p-5">
            <.section_heading id="payroll-mappings" title="Pay-item mappings" />
            <p id="attendance-mapping-unavailable" class="mt-2 text-sm text-ink-muted">
              Attendance — not available yet. Allowance rules are not available for mapping.
            </p>
            <.empty_state
              :if={@data.mappings == []}
              id="mappings-empty"
              title="No Leave or Claims mappings yet."
            />
            <ul class="mt-3 divide-y divide-line text-sm">
              <li :for={row <- @data.mappings} class="py-2">
                {row.source_kind} · {row.source_key} → {item_name(@data.items, row.item_id)} · {row.effective_from} to {row.effective_to ||
                  "open"}
              </li>
            </ul>
            <p :if={@data.items == [] or @sources == []} class="mt-2 text-sm text-ink-muted">
              Add pay items and available Leave or Claims types before mapping.
            </p>
            <form
              :if={@can_manage? and @data.items != [] and @sources != []}
              id="mapping-form"
              phx-submit="create_mapping"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.choice
                name="record[source]"
                label="Mapping source"
                options={Enum.map(@sources, &{&1.value, &1.label})}
              />
              <.choice
                name="record[item_id]"
                label="Mapped pay item"
                options={Enum.map(@data.items, &{&1.id, "#{&1.name} · #{&1.effective_from}"})}
              />
              <.date_fields /><.button type="submit">Add mapping version</.button>
            </form>
          </.card>
          <.card inner_class="p-5">
            <.section_heading id="payroll-runs" title="Frozen setup" />
            <p class="mt-2 text-sm text-ink-muted">
              Freeze a period's setup for a currency. Locking is permanent. Calculation and financial outputs are not available yet.
            </p>
            <.empty_state :if={@data.runs == []} id="runs-empty" title="No frozen runs yet." />
            <div
              :for={run <- @data.runs}
              id={"run-#{run.id}"}
              class="mt-3 flex flex-wrap items-center gap-3 text-sm"
            >
              <span>Period {run.period_id} · {run.currency} · {run.country}</span>
              <span :if={run.locked_at}>Locked
              <.datetime id={"run-locked-#{run.id}"} value={run.locked_at} /></span>
              <.button
                :if={@can_manage? and is_nil(run.locked_at)}
                phx-click="lock_run"
                phx-value-id={run.id}
              >Lock permanently</.button>
            </div>
            <form
              :if={
                @can_manage? and @data.periods != [] and @data.currencies != [] and
                  @data.country != ""
              }
              id="run-form"
              phx-submit="create_run"
              class="mt-3 flex flex-wrap gap-3"
            >
              <.choice
                name="period_id"
                label="Run period"
                options={Enum.map(@data.periods, &{&1.id, &1.code})}
              />
              <.choice
                name="currency"
                label="Run currency"
                options={Enum.map(@data.currencies, &{&1, &1})}
              />
              <.button type="submit">Freeze setup</.button>
            </form>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp item_name(rows, id),
    do: Enum.find_value(rows, "Unavailable item", &(&1.id == id && &1.name))

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: "")
  attr(:type, :string, default: "text")
  attr(:required, :boolean, default: true)

  defp field(assigns) do
    ~H"""
    <label class="flex flex-col gap-1 text-sm">{@label}<input
      name={@name}
      type={@type}
      value={@value}
      required={@required}
      class="rounded-md border border-line bg-surface p-2"
    /></label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:options, :list, required: true)

  defp choice(assigns) do
    ~H"""
    <label class="flex flex-col gap-1 text-sm">{@label}<select
      name={@name}
      class="rounded-md border border-line bg-surface p-2"
    ><option :for={{value, label} <- @options} value={value}>{label}</option></select></label>
    """
  end

  defp catalog_fields(assigns) do
    ~H"""
    <.field name="record[code]" label="Code" /><.field name="record[name]" label="Name" />
    """
  end

  defp date_fields(assigns) do
    ~H"""
    <.field name="record[effective_from]" label="Effective from" type="date" /><.field
      name="record[effective_to]"
      label="Effective to"
      type="date"
      required={false}
    />
    """
  end
end
