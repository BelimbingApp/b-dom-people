defmodule Bilimbi.People.Workforce.EmploymentOwner do
  @moduledoc """
  People's side of Core Employee's employment-owner seam.

  Core still accepts HR writes on its deprecated path. When the Core in use
  exposes `register_employment_owner/1`, People registers this module at
  startup and Core calls `legacy_employee_written/2` inside the transaction of
  each such write, after its own locks, so People's record never trails Core's
  compatibility columns. Core's `unregister_employment_owner/1` undoes it at
  shutdown. A Core without the seam is left alone: nothing is registered, and
  `registered?/0` stays false, which keeps the `:legacy_drift` reads.

  Registering drops those reads, so first it runs the idempotent claim
  (`Employments.backfill/0`) that adopts Core's values for every drifted row.
  That makes the transition safe on every start, with no persisted state: a
  start with nothing drifted adopts nothing. If the pass fails, for example
  because the migrations have not run yet, People stays unregistered and
  keeps reading drift from Core until the next start.

  The seam is looked up by name at runtime, so People compiles and runs
  against a Core that predates it.
  """

  require Logger

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Employments

  @key {__MODULE__, :core}

  @doc "Registers as Core's employment owner when Core offers the seam."
  @spec register(module()) :: :ok | {:error, :unavailable | :not_adopted}
  def register(core \\ Employee) when is_atom(core) do
    if Code.ensure_loaded?(core) and function_exported?(core, :register_employment_owner, 1) do
      case adopt_drift() do
        :ok ->
          apply(core, :register_employment_owner, [__MODULE__])
          :persistent_term.put(@key, core)
          :ok

        {:error, reason} ->
          Logger.warning(
            "People employment owner not registered; drift was not adopted: #{inspect(reason)}"
          )

          {:error, :not_adopted}
      end
    else
      {:error, :unavailable}
    end
  end

  defp adopt_drift do
    Employments.backfill()
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Removes the registration this module made, if any."
  @spec unregister() :: :ok
  def unregister do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok

      core ->
        :persistent_term.erase(@key)

        if function_exported?(core, :unregister_employment_owner, 1),
          do: apply(core, :unregister_employment_owner, [__MODULE__])

        :ok
    end
  end

  @doc "Whether Core routes its deprecated HR writes to People."
  @spec registered?() :: boolean()
  def registered?, do: :persistent_term.get(@key, nil) != nil

  @doc """
  Core's callback: the legacy employee row was just written in this
  transaction. People adopts the written values, or claims the row when it
  holds none yet. A row People cannot claim is recorded as an exception and
  never blocks Core's write.
  """
  @spec legacy_employee_written(Scope.t(), pos_integer()) :: :ok
  def legacy_employee_written(%Scope{} = scope, employee_id),
    do: Employments.legacy_written(scope, employee_id)
end
