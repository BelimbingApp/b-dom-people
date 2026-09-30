defmodule Bilimbi.People.Skills.Policy do
  @moduledoc false
  # Company-scoped Base Settings that steer assessments, development actions
  # and reminders. Historical facts snapshot the value they used.

  alias Bilimbi.Base.Settings
  alias Bilimbi.People.Skills.Access

  @keys %{
    reassessment_due_days: "people.skills.reassessment_due_days",
    default_reassessment_months: "people.skills.default_reassessment_months",
    reminder_window_days: "people.skills.reminder_window_days",
    backup_minimum: "people.skills.backup_minimum",
    multiplier_critical: "people.skills.priority_multiplier_critical",
    multiplier_essential: "people.skills.priority_multiplier_essential",
    multiplier_development: "people.skills.priority_multiplier_development"
  }

  @ranges %{
    reassessment_due_days: 1..365,
    default_reassessment_months: 1..120,
    reminder_window_days: 0..365,
    backup_minimum: 1..100,
    multiplier_critical: 0..100,
    multiplier_essential: 0..100,
    multiplier_development: 0..100
  }

  def keys, do: @keys

  def get(scope, company_id) do
    with {:ok, company} <- Access.current_company(scope, company_id) do
      settings_scope = Access.settings_scope(scope, company)
      {:ok, Map.new(@keys, fn {name, key} -> {name, Settings.get(key, settings_scope)} end)}
    end
  end

  @doc "Stores the given values; omitted policy values keep their current value."
  def put(scope, company_id, %{} = changes) do
    with :ok <- validate(changes),
         {:ok, company} <- Access.current_company(scope, company_id) do
      settings_scope = Access.settings_scope(scope, company)

      changes
      |> Enum.reduce_while(:ok, fn {name, value}, :ok ->
        case Settings.put(Map.fetch!(@keys, name), value, settings_scope) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> get(scope, company_id)
        error -> error
      end
    end
  end

  def put(_scope, _company_id, _changes), do: {:error, :invalid_policy}

  def multiplier(policy, "critical"), do: policy.multiplier_critical
  def multiplier(policy, "essential"), do: policy.multiplier_essential
  def multiplier(policy, "development"), do: policy.multiplier_development

  defp validate(changes) do
    if changes != %{} and
         Enum.all?(changes, fn {name, value} ->
           range = Map.get(@ranges, name)
           range != nil and is_integer(value) and value in range
         end),
       do: :ok,
       else: {:error, :invalid_policy}
  end
end
