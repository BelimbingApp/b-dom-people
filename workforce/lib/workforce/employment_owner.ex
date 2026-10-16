defmodule Bilimbi.People.Workforce.EmploymentOwner do
  @moduledoc """
  People's side of Core Employee's employment-owner seam.

  Core still accepts HR writes on its deprecated path. When the Core in use
  exposes `register_employment_owner/1`, People registers this module at
  startup and Core calls `legacy_employee_written/2` with
  `%{employee_id: _, person_id: _, affiliation_id: _}` inside the transaction
  of each such write, after its own locks, so People's record never trails
  Core's compatibility columns. Core's `unregister_employment_owner/1` undoes it at
  shutdown. A Core without the seam is left alone: nothing is registered, and
  `registered?/0` stays false, which keeps the `:legacy_drift` reads.

  Registering drops those reads, so first it runs the idempotent claim
  (`Employments.backfill/0`) that adopts Core's values for every drifted row.
  That makes the transition safe on every start, with no persisted state: a
  start with nothing drifted adopts nothing. If the pass fails, for example
  because the migrations have not run yet, People stays unregistered and
  keeps reading drift from Core until the next start. A second pass runs
  after a grace period (`grace_pass_child/0`); `workforce/docs/README.md`
  owns the details.

  The seam is looked up by name at runtime, so People compiles and runs
  against a Core that predates it.
  """

  require Logger

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.Employments

  @key {__MODULE__, :core}
  @since_key {__MODULE__, :registered_since}
  @default_grace_ms 60_000

  @doc "Registers as Core's employment owner when Core offers the seam."
  @spec register(module()) :: :ok | {:error, :unavailable | :not_adopted}
  def register(core \\ Employee) when is_atom(core) do
    if Code.ensure_loaded?(core) and function_exported?(core, :register_employment_owner, 1) do
      # Core's timestamps have second precision, so the sweep starts a second early.
      since = NaiveDateTime.utc_now() |> NaiveDateTime.add(-1) |> NaiveDateTime.truncate(:second)

      with :ok <- adopt_drift(),
           :ok <- apply(core, :register_employment_owner, [__MODULE__]),
           :ok <- adopt_written_since(core, since) do
        :persistent_term.put(@key, core)
        :persistent_term.put(@since_key, since)
        :ok
      else
        {:error, reason} ->
          Logger.warning("People employment owner not registered: #{inspect(reason)}")
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

  # A row Core wrote after the backfill read it but before Core routed its
  # writes here is adopted now, before reads stop falling back to Core. On
  # failure Core's registration is undone so reads keep the fallback.
  defp adopt_written_since(core, since) do
    case Employments.adopt_written_since(since) do
      {:ok, adopted} ->
        if adopted > 0,
          do:
            Logger.info(
              "People employment owner adopted #{adopted} rows Core wrote while registering"
            )

        :ok

      {:error, reason} ->
        apply(core, :unregister_employment_owner, [__MODULE__])
        {:error, reason}
    end
  rescue
    error ->
      apply(core, :unregister_employment_owner, [__MODULE__])
      {:error, Exception.message(error)}
  end

  @doc """
  The supervised child that runs the second registration pass after the
  grace period (`:employment_owner_grace_ms`, default 60 s), or `nil` when
  People is not registered.
  """
  @spec grace_pass_child() :: Supervisor.child_spec() | nil
  def grace_pass_child do
    if registered?() do
      grace =
        Application.get_env(
          :bilimbi_people_workforce,
          :employment_owner_grace_ms,
          @default_grace_ms
        )

      Supervisor.child_spec(
        {Task,
         fn ->
           Process.sleep(grace)
           run_grace_pass()
         end},
        id: {__MODULE__, :grace_pass},
        restart: :temporary
      )
    end
  end

  @doc """
  The second registration pass: adopts rows Core wrote, and claims rows Core
  created, since just before registration, comparing `updated_at` as the
  first pass does. Catches writes that were in flight when Core accepted the
  registration and so reached neither the first pass nor the callback. Logs
  what it adopted.
  """
  @spec run_grace_pass() :: :ok | {:error, term()}
  def run_grace_pass do
    case :persistent_term.get(@since_key, nil) do
      nil ->
        :ok

      since ->
        case Employments.adopt_written_since(since) do
          {:ok, count} ->
            if count > 0,
              do:
                Logger.info(
                  "People employment owner adopted #{count} rows in flight at registration"
                )

            :ok

          {:error, reason} = error ->
            Logger.warning("People employment owner grace pass failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc "The owner's name, as Core's employee pages say who owns the HR facts."
  @spec name() :: String.t()
  def name, do: "People"

  @doc "Removes the registration this module made, if any."
  @spec unregister() :: :ok
  def unregister do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok

      core ->
        :persistent_term.erase(@key)
        :persistent_term.erase(@since_key)

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
  transaction, after Core's company, person and employee locks. People adopts
  the written values, or claims the row with the `person_id` and
  `affiliation_id` Core read there; unknown keys are ignored. A row People
  cannot claim is recorded as an exception and never blocks Core's write.
  """
  @spec legacy_employee_written(Scope.t(), map()) :: :ok
  def legacy_employee_written(%Scope{} = scope, %{employee_id: employee_id} = written)
      when is_integer(employee_id) do
    Employments.legacy_written(
      scope,
      employee_id,
      Map.get(written, :person_id),
      Map.get(written, :affiliation_id)
    )
  end
end
