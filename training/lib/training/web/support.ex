defmodule Bilimbi.People.Training.Web.Support do
  @moduledoc false
  alias Bilimbi.Core.Company

  def companies(current_scope, capability) do
    case Company.list_selectable_companies(current_scope.scope, capability) do
      {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
      _ -> []
    end
  end

  def company(companies, params) do
    case params["company_id"] do
      nil -> List.first(companies)
      id -> Enum.find(companies, &(to_string(&1.id) == id))
    end
  end

  def integer(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def message(:passport_too_large),
    do:
      "This passport exceeds the document safety limit of 1,000 records. Review records on screen."

  def message(:invalid_insight_range),
    do: "Choose valid dates in order, covering at most 366 days."

  def message(:report_period_unavailable),
    do:
      "Choose a frozen Effectiveness reporting period. Periods appear once an operator freezes them."

  def message(:forbidden),
    do:
      "You cannot access or generate this document. Ask an operator to check your access and workforce connection."

  def message(:storage_not_configured),
    do: "Ask an operator to configure private document storage in Operator Settings."

  def message(:unsupported_text),
    do:
      "This document contains characters the available PDF renderer cannot display. The training records remain available on screen."

  def message(:policy_not_configured),
    do: "Save this company's evaluation settings on Effectiveness before publication."

  def message(:report_not_configured),
    do: "Save this company's evaluation settings on Effectiveness first."

  def message(:invalid_checkpoints),
    do: "Set distinct positive checkpoint day offsets in the evaluation settings."

  def message(:invalid_evaluation_settings),
    do:
      "Enter whole-number days, a disclosure minimum of at least 2, a reporting period that divides 12 months, and 1 to 24 distinct checkpoint days."

  def message(:invalid_criteria),
    do: "Supply unique criterion codes, labels and ordered whole-number score bounds."

  def message(:invalid_answers),
    do: "Answer every criterion within its score bounds, or leave its outcome explicitly unknown."

  def message(:overlapping_policy),
    do: "Choose an effective period that does not overlap a published policy."

  def message(:invalid_period), do: "The effective end date must be on or after the start."
  def message(:reason_required), do: "Supply an explanation for this permanent record."
  def message(:session_not_finished), do: "Reviews can be prepared after this session ends."

  def message(:policy_unavailable),
    do: "Publish a policy covering the session's local completion date first."

  def message(:attendance_unavailable),
    do: "This employee's latest attendance is not confirmed. Check the session record."

  def message(:already_answered), do: "This review already has a permanent answer."
  def message(:outside_team), do: "This employee is outside your current direct-report team."
  def message(:session_unavailable), do: "Choose a session in this company."
  def message(:employee_unavailable), do: "Choose a current employee in this company."

  def message(:import_conflict),
    do: "This record key already belongs to different attendance. Use a new key for a correction."

  def message(:invalid_record), do: "Supply a session, employee, record key and reason."
  def message(:invalid_pdf), do: "Choose a PDF evidence document."

  def message(:retention_not_configured),
    do: "Ask an operator to configure document retention in Operator Settings."

  def message(:upload_required), do: "Choose an evidence PDF first."

  def message(:ambiguous_time),
    do: "That local time occurs twice. Choose a time outside the clock overlap."

  def message(:nonexistent_time),
    do: "That local time does not exist. Choose a time after the clock change."

  def message(:invalid_time_zone_or_time), do: "Enter valid local times and an IANA time zone."
  def message(:invalid_time_range), do: "The end must be after the start."

  def message(:attendance_capacity_exceeded),
    do:
      "This session has no remaining attendance places. Correct an existing record or ask a session operator to review capacity."

  def message(:capacity_exceeded), do: "Session capacity cannot exceed event capacity."
  def message(:course_unavailable), do: "Choose an active course in this company."
  def message(:event_unavailable), do: "Choose an event in this company."
  def message(:unauthorized), do: "You cannot do that for this company."
  def message(:not_found), do: "That record is not available to you."

  def message({:not_current, freshness}),
    do:
      Bilimbi.People.Training.Passport.workforce_warning(%Bilimbi.People.Workforce.ReadResult{
        freshness: freshness
      })

  def message(:company_unavailable), do: "Choose an active company."

  def message(%Ecto.Changeset{data: %Bilimbi.People.Training.EvaluationPolicy{}}),
    do: "Enter valid effective dates and a publication reason."

  def message(%Ecto.Changeset{}),
    do:
      "Check the entered values. Codes must be unique and capacity must be a positive whole number."

  def message(_), do: "That could not be completed. Refresh and try again."

  def page(records, params, key \\ "page") do
    size =
      case integer(params["perPage"] || "25") do
        n when n in [25, 50, 100, 300] -> n
        _ -> 25
      end

    total = length(records)
    pages = ceil(total / size)
    number = max(1, min(integer(params[key] || "1") || 1, max(pages, 1)))

    %{
      entries: Enum.slice(records, (number - 1) * size, size),
      page: number,
      page_size: size,
      total_entries: total,
      total_pages: pages
    }
  end
end
