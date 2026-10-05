defmodule Bilimbi.People.Skills.Web.Support do
  @moduledoc false
  # Shared LiveView helpers: company choice, form coercion and refusal wording.
  alias Bilimbi.People.Workforce.Authorization

  def companies(scope, capability) do
    case Authorization.selectable_companies(scope, capability) do
      {:ok, values} -> Enum.filter(values, &(&1.status == "active"))
      _ -> []
    end
  end

  def pick_company(companies, params),
    do:
      Enum.find(companies, &(Map.get(params, "company_id") == to_string(&1.id))) ||
        List.first(companies)

  def to_integer(value) when is_integer(value), do: value

  def to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  def to_integer(_value), do: nil

  def blank_to_nil(attrs),
    do: Map.new(attrs, fn {key, value} -> {key, if(value == "", do: nil, else: value)} end)

  def new_key, do: Ecto.UUID.generate()

  def input_class, do: "rounded-md border border-line bg-surface px-3 py-2 text-sm"

  def message({:not_current, _freshness}),
    do: "The workforce is not current, so nothing was changed."

  def message(:unauthorized), do: "You cannot do that for this company."
  def message(:not_found), do: "That record is not available to you."
  def message(:out_of_reach), do: "That employee is outside the people you may act on."
  def message(:self_assessment), do: "You cannot assess yourself."
  def message(:self_approval), do: "You cannot decide on work you did or that concerns you."
  def message(:self_request), do: "You cannot request your own reassessment."

  def message(:no_requirement),
    do: "No published requirement covers that skill for this employee."

  def message(:level_not_on_scale),
    do: "That level is not on the requirement's proficiency scale."

  def message(:skill_unavailable), do: "That skill is not available."
  def message(:key_conflict), do: "That submission was already used for a different record."
  def message(:future_assessment), do: "An assessment cannot be dated in the future."
  def message(:invalid_validity), do: "The validity date cannot be before the assessment date."
  def message(:not_supersedable), do: "That assessment cannot be corrected."

  def message(:not_original_assessor),
    do: "Only the original assessor can correct a returned assessment."

  def message(:already_superseded), do: "That assessment already has a correction."
  def message(:not_pending), do: "That item is no longer pending."
  def message(:not_verified), do: "Only a verified assessment can be finalized."
  def message(:note_required), do: "A note is required to return an assessment."
  def message(:no_score), do: "The employee has no current score for that skill."
  def message(:already_open), do: "A reassessment is already open for that employee and skill."
  def message(:reason_required), do: "A reason is required."
  def message(:evidence_required), do: "Evidence is required."
  def message(:type_unavailable), do: "Choose an active action type."
  def message(:provider_required), do: "This action type needs a trainer, coach or provider."
  def message(:employee_unavailable), do: "Every named person must be a current employee."
  def message(:already_proposed), do: "That assessment already has a development action."

  def message(:not_actionable),
    do: "Only a current gap or an expired critical skill needs an action."

  def message(:not_current), do: "Only the employee's current assessment can start an action."
  def message(:invalid_transition), do: "The action cannot move from its current status."
  def message(:not_proposed), do: "Only a proposed action can be changed this way."

  def message(:not_a_reassessment),
    do: "That is not a finalized reassessment after the intervention."

  def message(:invalid_policy), do: "Enter whole numbers within the shown limits."
  def message(%Ecto.Changeset{}), do: "Check the entered values."
  def message(_reason), do: "That could not be done."
end
