defmodule Bilimbi.People.Performance.WebSupport do
  @moduledoc false
  def integer(value) when is_integer(value), do: value

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> id
      _ -> nil
    end
  end

  def integer(_), do: nil

  def attrs(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {key, if(value == "", do: nil, else: value)} end)

    attrs =
      Enum.reduce(
        ~w(employee_id position_id position_version definition_id description_id version precision supersedes_id),
        attrs,
        fn key, acc ->
          if Map.has_key?(acc, key), do: Map.update!(acc, key, &integer/1), else: acc
        end
      )

    attrs =
      Enum.reduce(~w(observation_ids target_ids), attrs, fn key, acc ->
        if Map.has_key?(acc, key),
          do:
            Map.update!(acc, key, fn value ->
              values =
                if is_list(value), do: value, else: String.split(value || "", ",", trim: true)

              Enum.map(values, &integer(String.trim(&1)))
            end),
          else: acc
      end)

    attrs =
      if attrs["profile_id"],
        do:
          Map.put(attrs, "competency_links", [
            %{
              "id" => integer(attrs["profile_id"]),
              "version" => integer(attrs["profile_version"])
            }
          ]),
        else: attrs

    if attrs["cutoff_at"] && not String.ends_with?(attrs["cutoff_at"], "Z"),
      do: Map.update!(attrs, "cutoff_at", &(&1 <> ":00Z")),
      else: attrs
  end

  def message(%Ecto.Changeset{}), do: "Check the required fields and their values."

  def message(:impersonation_refused),
    do: "End impersonation before recording performance decisions."

  def message(:unauthorized), do: "You cannot do that for this company."
  def message(:not_found), do: "That record is not available to you."
  def message(:out_of_reach), do: "Choose a current employee who reports directly to you."
  def message(:unavailable), do: "A current employee must be linked to this account."
  def message(:profile_unavailable), do: "Choose an exact published competency profile version."

  def message(:position_version_unavailable),
    do: "The position version is not applicable on that date."

  def message(:position_unavailable), do: "That position is not available in this company."
  def message(:overlapping_description), do: "A published description already covers these dates."

  def message(:assignment_unavailable),
    do: "The position assignment must cover the review period."

  def message(:description_unavailable),
    do: "A published position description must cover the review period."

  def message(:self_approval), do: "The author and the employee cannot approve their own record."

  def message(:not_publishable),
    do: "Only a reviewed, non-confidential target can be communicated."

  def message(:evidence_required), do: "Pin at least one observation and communicated target."

  def message(:evidence_outside_window),
    do: "The evidence must concern this employee, period and cutoff."

  def message(:target_unavailable),
    do: "The target must be communicated to this employee within this period and cutoff."

  def message(:future_cutoff), do: "The cutoff has not passed yet."
  def message(:already_corrected), do: "This version already has a correction."
  def message(:invalid_dates), do: "Check the period, effective dates and UTC cutoff."
  def message(:reason_required), do: "State the reason for this decision or correction."
  def message(:not_author), do: "Only the original author can correct this released record."

  def message(:invariant_refused),
    do: "The record conflicts with existing history or release rules."

  def message({:not_current, _}),
    do: "The workforce is not current. Try again when its data is available."

  def message(_), do: "The record cannot move from its current state."
end
