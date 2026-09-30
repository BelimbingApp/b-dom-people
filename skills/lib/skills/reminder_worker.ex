defmodule Bilimbi.People.Skills.ReminderWorker do
  @moduledoc """
  Sends one company's due skill reminders as the operator who queued the job.

  The operator's company reach and `people.skills.reminders.send` are checked
  again when the job runs. The reminder ledger makes the run idempotent, so a
  retried or repeated job notifies nobody twice in the same period.
  """
  use Bilimbi.Base.Queue.Worker, id: "people-skills/reminders", max_attempts: 5

  alias Bilimbi.Base.Authz
  alias Bilimbi.People.Skills

  @impl true
  def validate_args(%{"company_id" => company_id})
      when is_integer(company_id) and company_id > 0,
      do: {:ok, %{"company_id" => company_id}}

  def validate_args(_args), do: {:error, :invalid_reminders}

  @impl true
  def handle_job(%{"company_id" => company_id}, %{scope: scope}) when not is_nil(scope) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, _counts} <- Skills.issue_reminders(actor, company_id) do
      :ok
    else
      {:error, {:not_current, _freshness}} -> {:retry, :workforce_not_current}
      _ -> {:cancel, :not_authorized}
    end
  end

  def handle_job(_args, _execution), do: {:cancel, :not_authorized}
end
