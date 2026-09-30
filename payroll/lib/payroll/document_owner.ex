defmodule Bilimbi.People.Payroll.DocumentOwner do
  @moduledoc "Trusted payroll adapter for Base Artifacts; documents require final approval."
  @behaviour Bilimbi.Base.Artifacts.Owner
  @behaviour Bilimbi.Base.Artifacts.PDF
  alias Bilimbi.People.Payroll

  @impl true
  def artifact_owner_id, do: "people/payroll"
  @impl true
  def authorize(scope, company, operation, reference),
    do: Payroll.document_access(scope, company, operation, reference)

  @impl true
  def render_pdf(scope, company, reference, data) do
    # Re-read the approved frozen result rather than trusting caller PDF data.
    with {:ok, frozen} <- Payroll.document_data(scope, company, reference, data.employee_id) do
      text = ["Payroll #{reference.kind} - run #{reference.subject}",
        "Currency: #{frozen.currency}", "Calculation: #{frozen.digest}"] ++
        Enum.map(frozen.lines, fn line ->
          "Employee #{line["employee_id"]} / item #{line["item_id"]} / #{line["direction"]}: " <>
            "#{line["units"]} x #{line["rate"]} = #{line["amount"]}"
        end) ++ Enum.map(frozen.totals, fn total ->
          "Employee #{total["employee_id"]}: earnings #{total["earning"]}, " <>
            "deductions #{total["deduction"]}, net #{total["net"]}, employer #{total["employer"]}"
        end)
      {:ok, Bilimbi.People.Payroll.PDF.render(text)}
    end
  end
end
