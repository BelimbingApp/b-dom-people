defmodule Bilimbi.People.Leave.CarryForwardWorker do
  @moduledoc """
  Runs one company's year-end carry-forward as the operator who queued it.

  The operator's company reach and `people.leave.policies.manage` are checked
  again when the job runs. The run itself is idempotent, so a retried or
  repeated job changes nothing already carried.
  """
  use Bilimbi.Base.Queue.Worker, id: "people-leave/carry-forward", max_attempts: 5

  alias Bilimbi.Base.Authz
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Leave

  @capability "people.leave.policies.manage"

  @impl true
  def validate_args(%{"company_id" => company_id, "from_year" => year})
      when is_integer(company_id) and company_id > 0 and is_integer(year) and
             year in 1900..9997,
      do: {:ok, %{"company_id" => company_id, "from_year" => year}}

  def validate_args(_args), do: {:error, :invalid_carry_forward}

  @impl true
  def handle_job(%{"company_id" => company_id, "from_year" => year}, %{scope: scope})
      when not is_nil(scope) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, companies} <- Company.list_selectable_companies(actor, @capability),
         true <- Enum.any?(companies, &(&1.id == company_id and &1.status == "active")) do
      case Leave.carry_forward(scope, company_id, year, actor.id) do
        {:ok, _counts} -> :ok
        {:error, :not_current} -> {:retry, :workforce_not_current}
        {:error, :year_not_ended} -> {:cancel, :year_not_ended}
        {:error, _reason} -> {:cancel, :carry_forward_refused}
      end
    else
      _ -> {:cancel, :not_authorized}
    end
  end

  def handle_job(_args, _execution), do: {:cancel, :not_authorized}
end
