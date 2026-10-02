defmodule Bilimbi.People.Payroll.Web.RunsLive do
  @moduledoc "Review frozen payroll, attest contributions, calculate and independently decide."
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Payroll
  @manage_events ~w(intake calculate generate_report generate_payslip)

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
       page_title: "Payroll runs",
       companies: companies,
       company: nil,
       data: nil,
       output: nil,
       can_manage?: false,
       can_approve?: false,
       intake_form: to_form(%{}, as: "input"),
       decision_form: to_form(%{}, as: "decision")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    company =
      if params["company_id"],
        do: Enum.find(socket.assigns.companies, &(to_string(&1.id) == params["company_id"])),
        else: List.first(socket.assigns.companies)

    {:noreply, socket |> assign(company: company, output: nil) |> load(integer(params["run_id"]))}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @manage_events,
      do: {:noreply, put_flash(socket, :error, "You cannot change this company's payroll runs.")}

  def handle_event("decide", _params, %{assigns: %{can_approve?: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "You cannot approve this company's payroll runs.")}

  def handle_event("select_company", %{"company_id" => company}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/people/payroll/runs?company_id=#{company}")}

  def handle_event("intake", %{"input" => attrs}, socket) do
    mode = attrs["source_kind"]

    result =
      cond do
        mode == "attendance" ->
          Payroll.intake_attendance_allowance(
            scope(socket),
            company(socket),
            run(socket),
            Map.put(attrs, "attendance_rule_code", attrs["mapping_source"])
          )

        mode in ["leave", "claims"] ->
          Payroll.intake_mapped(
            scope(socket),
            company(socket),
            run(socket),
            mode,
            attrs["mapping_source"],
            attrs
          )

        true ->
          Payroll.intake(scope(socket), company(socket), run(socket), attrs)
      end

    outcome(socket, result)
  end

  def handle_event("calculate", _, socket),
    do: outcome(socket, Payroll.calculate(scope(socket), company(socket), run(socket)))

  def handle_event("decide", %{"decision" => attrs}, socket),
    do:
      outcome(
        socket,
        Payroll.decide_run(
          scope(socket),
          company(socket),
          run(socket),
          attrs["outcome"],
          attrs["reason"]
        )
      )

  def handle_event("generate_report", _, socket),
    do:
      outcome(
        socket,
        Payroll.generate_document(scope(socket), company(socket), run(socket), "report")
      )

  def handle_event("generate_payslip", %{"employee" => employee}, socket),
    do:
      outcome(
        socket,
        Payroll.generate_document(
          scope(socket),
          company(socket),
          run(socket),
          "payslip",
          integer(employee)
        )
      )

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company(socket), do: socket.assigns.company.id
  defp run(%{assigns: %{output: nil}}), do: nil
  defp run(socket), do: socket.assigns.output.run.id

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp load(%{assigns: %{company: nil}} = socket, _),
    do: assign(socket, data: nil, output: nil, can_manage?: false, can_approve?: false)

  defp load(socket, run_id) do
    with {:ok, data} <- Payroll.setup(scope(socket), company(socket)) do
      output =
        case Payroll.run_output(scope(socket), company(socket), run_id) do
          {:ok, output} -> output
          _ -> nil
        end

      assign(socket,
        data: data,
        output: output,
        can_manage?: Payroll.allowed?(scope(socket), company(socket), "people.payroll.manage"),
        can_approve?: Payroll.allowed?(scope(socket), company(socket), "people.payroll.approve")
      )
    else
      _ -> assign(socket, data: nil, output: nil, can_manage?: false, can_approve?: false)
    end
  end

  defp outcome(socket, {:ok, _}),
    do:
      {:noreply, socket |> put_flash(:success, "Payroll action completed.") |> load(run(socket))}

  defp outcome(socket, {:error, %Ecto.Changeset{}}),
    do:
      {:noreply,
       put_flash(socket, :error, "Check the contribution fields and exact decimal units.")}

  defp outcome(socket, {:error, reason}),
    do: {:noreply, put_flash(socket, :error, "Payroll action refused: #{inspect(reason)}")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav="people.payroll.runs">
      <.page id="payroll-runs-page">
        <.header>
          Payroll runs<:subtitle>
            Frozen rates, attested contributions and independent approval
          </:subtitle>
        </.header>
        <.form
          :if={@companies != []}
          for={to_form(%{})}
          id="runs-company"
          phx-change="select_company"
          phx-submit="select_company"
        >
          <.input
            type="select"
            name="company_id"
            label="Company"
            value={@company && @company.id}
            options={Enum.map(@companies, &{&1.name, &1.id})}
          />
        </.form>
        <.empty_state
          :if={is_nil(@data)}
          id="payroll-runs-unavailable"
          title="Payroll is unavailable for this company."
        />
        <div :if={@data} class="space-y-4">
          <.card inner_class="p-5">
            <.section_heading id="frozen-runs" title="Runs" />
            <p class="mt-2 text-sm text-ink-muted">
              Create and permanently lock setup in
              <.link navigate={~p"/people/payroll/setup?company_id=#{@company.id}"}>Payroll setup</.link>
              before calculating.
            </p>
            <.empty_state
              :if={@data.runs == []}
              id="payroll-no-runs"
              title="No frozen payroll runs yet."
            />
            <ul class="mt-3 divide-y divide-line text-sm">
              <li :for={row <- @data.runs} class="py-2">
                <.link patch={~p"/people/payroll/runs?company_id=#{@company.id}&run_id=#{row.id}"}>Run {row.id} · period {row.period_id} · {row.currency}</.link>
              </li>
            </ul>
          </.card>
          <.card :if={@output} inner_class="p-5">
            <.section_heading
              id="selected-run"
              title={"Run #{@output.run.id} · #{@output.run.currency}"}
            />
            <p :if={is_nil(@output.run.locked_at)} class="text-sm text-ink-muted">
              Setup must be locked before calculation.
            </p>
            <.empty_state
              :if={not @can_manage?}
              id="payroll-read-only"
              title="Read-only payroll access"
              reason="Ask a payroll operator to attest contributions and calculate."
            />
            <.section_heading id="run-contributions" title="Contributions" class="mt-4" />
            <p class="text-sm text-ink-muted">
              An operator attests employee, date, exact units, direction and source evidence. Mapped sources use their frozen pay-item rate. No statutory formula or allowance eligibility is inferred.
            </p>
            <.empty_state
              :if={@output.contributions == []}
              id="no-contributions"
              title="No contributions accepted."
            />
            <ul class="mt-2 text-sm">
              <li :for={input <- @output.contributions}>
                {input.source_key} · employee {input.employee_id} · {input.direction} · {Decimal.to_string(
                  input.units
                )} units
              </li>
            </ul>
            <.form
              :if={@can_manage? and is_nil(@output.calculation)}
              for={@intake_form}
              id="contribution-form"
              phx-submit="intake"
              class="mt-3 grid gap-3 sm:grid-cols-3"
            >
              <.input field={@intake_form[:source_key]} label="Unique contribution key" required />
              <.input field={@intake_form[:employee_id]} label="Employee ID" type="number" required />
              <.input
                field={@intake_form[:source_kind]}
                label="Source"
                type="select"
                options={[
                  {"Direct pay item", "direct"},
                  {"Attendance allowance", "attendance"},
                  {"Leave mapping", "leave"},
                  {"Claims mapping", "claims"}
                ]}
              />
              <.input field={@intake_form[:mapping_source]} label="Mapped source code or ID" />
              <.input
                field={@intake_form[:item_id]}
                label="Direct pay item"
                type="select"
                options={Enum.map(@output.run.snapshot["items"], &{&1["code"], &1["id"]})}
              />
              <.input field={@intake_form[:on_date]} label="Contribution date" type="date" required />
              <.input field={@intake_form[:units]} label="Exact units" required />
              <.input
                field={@intake_form[:direction]}
                label="Direction"
                type="select"
                options={[
                  {"Earning", "earning"},
                  {"Deduction", "deduction"},
                  {"Employer contribution", "employer"}
                ]}
              />
              <.input field={@intake_form[:evidence]} label="Source evidence reference" required />
              <.button type="submit">Accept contribution</.button>
            </.form>
            <.button
              :if={@can_manage? and not is_nil(@output.run.locked_at) and is_nil(@output.calculation)}
              phx-click="calculate"
              class="mt-3"
            >Calculate permanently</.button>
            <div :if={@output.calculation} id="payroll-result" class="mt-4 space-y-2">
              <.section_heading id="run-results" title="Frozen results" />
              <p class="break-all text-xs text-ink-muted">
                Replay digest: {@output.calculation.digest}
              </p>
              <ul class="text-sm tabular-nums">
                <li :for={line <- @output.calculation.snapshot["result"]["lines"]}>
                  Employee {line["employee_id"]} · {line["direction"]} · {line["units"]} × {line[
                    "rate"
                  ]} = {line["amount"]} {@output.run.currency}
                </li>
              </ul>
              <ul class="text-sm tabular-nums">
                <li :for={total <- @output.calculation.snapshot["result"]["totals"]}>
                  Employee {total["employee_id"]} · net {total["net"]} · employer {total["employer"]} {@output.run.currency}
                </li>
              </ul>
              <p :if={is_nil(@output.decision)} class="text-sm text-ink-muted">
                An independent approver must decide before documents can be generated. Run creators, calculators and contribution authors cannot decide their own work.
              </p>
              <.form
                :if={@can_approve? and is_nil(@output.decision)}
                for={@decision_form}
                id="decision-form"
                phx-submit="decide"
                class="flex flex-wrap gap-3"
              >
                <.input
                  field={@decision_form[:outcome]}
                  type="select"
                  label="Decision"
                  options={[{"Approve", "approved"}, {"Reject", "rejected"}]}
                />
                <.input field={@decision_form[:reason]} label="Decision reason" required />
                <.button type="submit">Record final decision</.button>
              </.form>
              <p :if={@output.decision} id="payroll-decision" class="text-sm">
                {@output.decision.outcome} by actor {@output.decision.created_by_actor_id}: {@output.decision.reason}
              </p>
              <div
                :if={@output.decision && @output.decision.outcome == "approved" && @can_manage?}
                class="flex flex-wrap gap-3"
              >
                <.button phx-click="generate_report">Generate report PDF</.button>
                <.button
                  :for={total <- @output.calculation.snapshot["result"]["totals"]}
                  phx-click="generate_payslip"
                  phx-value-employee={total["employee_id"]}
                >Payslip for employee {total["employee_id"]}</.button>
              </div>
              <p class="text-sm text-ink-muted">
                Private documents require an operator-configured Base Artifacts storage directory and retention period.
              </p>
              <ul>
                <li :for={doc <- @output.documents}>
                  <.link href={
                    ~p"/people/payroll/documents/#{doc.artifact_id}?company_id=#{@company.id}"
                  }>{doc.kind} · {doc.employee_id || "all employees"} · Download PDF</.link>
                </li>
              </ul>
            </div>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
