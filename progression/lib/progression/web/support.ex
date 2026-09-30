defmodule Bilimbi.People.Progression.Web.Support do
  @moduledoc false
  def integer(value) when is_integer(value), do: value

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  def integer(_), do: nil
  def message(%Ecto.Changeset{}), do: "Check the required policy fields."

  def message(:unauthorized),
    do: "You cannot do that for this company. Check your progression and evidence permissions."

  def message(:no_published_policy),
    do: "No progression policy has been published with an effective date on or before today."

  def message(:employee_unavailable), do: "A working employee must be linked to your account."

  def message(:invalid_rules),
    do: "Choose competency requirements or a performance period, and complete their criteria."

  def message(:profile_unavailable),
    do: "Choose an exact published competency profile with requirements."

  def message(:version_order),
    do: "Publish a version higher than the existing versions for this policy code."

  def message(:effective_order),
    do:
      "Choose an effective date on or after the latest published effective date for this policy code."

  def message(:invariant_refused),
    do: "This policy conflicts with immutable history or an existing version."

  def message(:already_published), do: "This policy version has already been published."
  def message(:impersonation_refused), do: "End impersonation before recording a policy."

  def message({:not_current, _}),
    do: "Current workforce data is unavailable. Try again when it is current."

  def message(_),
    do: "The record is unavailable. Check your company, employee link and evidence permissions."
end
