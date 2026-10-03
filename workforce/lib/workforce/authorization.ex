defmodule Bilimbi.People.Workforce.Authorization do
  @moduledoc """
  Per-operation authorization for People, and the signed-in actor's own employee.

  People LiveViews must recheck their route capability before acting, and a
  `can_*?` assign only decides which controls to render. Route authorization
  does not replace authority for an operation: an administrator can revoke
  the grant, or unlink the login account from its employee, while the page
  stays connected. Every People
  public write, and every public read of private employee facts, therefore
  calls this module first with the scope it was handed, so that LiveViews,
  jobs and other adapters share one boundary and a revocation takes effect on
  the very next operation.

  Pass the scope, never an actor or an actor ID. The actor is read with
  `Bilimbi.Base.Tenancy.Scope.actor/1`, which verifies the seal the
  authentication edge gave it, and a system scope names nobody, so it is
  refused. The capability is evaluated now, by `Bilimbi.Base.Authz`, and the
  company axis by `Bilimbi.Core.Company.authorize_company_target/3` with this
  scope, not the actor taken from it.

  Self-service operations act on the employee the login account is linked to
  *now*. `self_employee/2` resolves that link on every call, and
  `with_self_employee_lock/4` proves it again inside the transaction that
  holds the Core Employee affiliation lock, the same lock account replacement
  takes, so a withdrawal cannot commit for an employee the account no longer
  belongs to.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.Actor
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Actor, as: TenancyActor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @type refusal :: :unauthorized | :not_found
  @type self :: %{actor: Actor.t(), employee_id: pos_integer()}

  @doc """
  Authorizes the scope's signed-in actor for one capability in one company.

  Returns the authorization actor for attribution. `:unauthorized` covers a
  system scope, a denied or unknown capability, and a company outside the
  actor's reach; `:not_found` covers a company the scope cannot see at all.
  """
  @spec authorize(Scope.t(), term(), String.t()) :: {:ok, Actor.t()} | {:error, refusal()}
  def authorize(%Scope{} = scope, company_id, capability) when is_binary(capability) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, _company} <- Company.authorize_company_target(scope, company_id, capability) do
      {:ok, actor}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  @doc """
  Whether the actor currently holds the capability for the company.

  For deciding which controls to render. It is not authority for an
  operation: the operation calls `authorize/3` itself when it runs.
  """
  @spec allowed?(Scope.t(), term(), String.t()) :: boolean()
  def allowed?(%Scope{} = scope, company_id, capability),
    do: match?({:ok, _actor}, authorize(scope, company_id, capability))

  @doc """
  The working employee the signed-in actor's account is linked to in this
  company, resolved now through Core User and the workforce seam.

  `:not_linked` covers a system scope, an actor signed in to another company,
  an account without an employee link, and a linked employee who is not a
  current working employee of the company.
  """
  @spec self_employee(Scope.t(), term()) :: {:ok, pos_integer()} | {:error, :not_linked}
  def self_employee(%Scope{} = scope, company_id) do
    with %TenancyActor{type: :user, user_id: user_id, company_id: ^company_id} <-
           Scope.actor(scope),
         {:ok, %{employee_id: employee_id}} when is_integer(employee_id) <-
           User.get_user(scope, company_id, user_id),
         {:ok, read} <- Workforce.employee(scope, company_id, employee_id),
         {:ok, _employee} <- ReadResult.require_current(read) do
      {:ok, employee_id}
    else
      _ -> {:error, :not_linked}
    end
  end

  @doc "Authorizes the self-service capability, then resolves the actor's own employee."
  @spec authorize_self(Scope.t(), term(), String.t()) ::
          {:ok, self()} | {:error, refusal() | :not_linked}
  def authorize_self(%Scope{} = scope, company_id, capability) do
    with {:ok, actor} <- authorize(scope, company_id, capability),
         {:ok, employee_id} <- self_employee(scope, company_id) do
      {:ok, %{actor: actor, employee_id: employee_id}}
    end
  end

  @doc """
  Runs a self-service write under the actor's own employee affiliation lock.

  Authorizes the capability and resolves the linked employee, then opens a
  transaction, takes `Bilimbi.Core.Employee.lock_affiliation/3` for that
  employee, proves the account link again under the lock, and only then calls
  `fun` with `%{actor: actor, employee_id: employee_id}`. `fun` returns
  `{:ok, value}` or `{:error, reason}`; an error rolls the transaction back.
  A link that changed between the resolution and the lock is `:not_linked`.
  """
  @spec with_self_employee_lock(Scope.t(), term(), String.t(), (self() ->
                                                                  {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, refusal() | :not_linked | term()}
  def with_self_employee_lock(%Scope{} = scope, company_id, capability, fun)
      when is_function(fun, 1) do
    with {:ok, %{employee_id: employee_id} = self} <-
           authorize_self(scope, company_id, capability) do
      Repo.transaction(fn ->
        case Employee.lock_affiliation(scope, company_id, employee_id) do
          {:ok, _proof} ->
            case self_employee(scope, company_id) do
              {:ok, ^employee_id} -> run(fun, self)
              _ -> Repo.rollback(:not_linked)
            end

          {:error, _reason} ->
            Repo.rollback(:not_linked)
        end
      end)
    end
  end

  defp run(fun, self) do
    case fun.(self) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
