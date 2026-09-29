defmodule Bilimbi.People.Claims do
  @moduledoc """
  Company-scoped claim catalog, effective-dated claim policies, and claim
  requests.

  Every call takes a validated `Bilimbi.Base.Tenancy.Scope` and an explicit
  platform company ID. Claim currencies are the company-scoped Base Setting
  `people.claims.currencies`; its default is empty, so a company accepts no
  claim until an operator chooses its currencies. Each policy and request
  stores its own currency; nothing assumes one.

  Submission is for a working employee read through the People workforce seam
  and is serialized per employee through Core Employee's affiliation lock, so
  duplicate and period-limit checks cannot race each other.
  """

  import Ecto.Query

  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User
  alias Bilimbi.People.Claims.{Category, ClaimType, Policy, Request, RequestEvent}
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @currencies_key "people.claims.currencies"
  @max_currencies 20

  @category_fields [:id, :code, :name, :active]
  @type_fields [:id, :category_id, :code, :name, :receipt_requirement, :active]
  @policy_fields [
    :id,
    :claim_type_id,
    :effective_from,
    :effective_to,
    :currency,
    :per_claim_limit,
    :monthly_limit,
    :yearly_limit,
    :receipt_threshold
  ]
  @request_fields [
    :id,
    :employee_id,
    :claim_type_id,
    :claim_policy_id,
    :incurred_on,
    :amount,
    :currency,
    :description,
    :receipt_number,
    :status,
    :duplicate_confirmed,
    :submitted_by_actor_id,
    :submitted_at,
    :withdrawn_by_actor_id,
    :withdrawn_at
  ]

  ## Currencies

  @doc "The company's allowed claim currencies, in operator order."
  def currencies(%Scope{} = scope, company_id) do
    with {:ok, company} <- company(scope, company_id), do: {:ok, company_currencies(company)}
  end

  @doc """
  Replaces the company's allowed claim currencies with ISO 4217-shaped codes.

  An empty list closes new claims and policies for the company.
  """
  def put_currencies(%Scope{} = scope, company_id, codes) do
    with {:ok, company} <- company(scope, company_id),
         {:ok, codes} <- normalize_currencies(codes) do
      Settings.put(@currencies_key, codes, settings_scope(company))
    end
  end

  ## Catalog

  def categories(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(Category, scope, company_id)
       |> order_by([c], asc: c.name, asc: c.id)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @category_fields))}
    end
  end

  def create_category(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- company(scope, company_id) do
      %Category{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Category.changeset(attrs)
      |> Repo.insert()
      |> map_result(&Map.take(&1, @category_fields))
    end
  end

  def set_category_active(%Scope{} = scope, company_id, category_id, active)
      when is_boolean(active) do
    with {:ok, _company} <- company(scope, company_id),
         %Category{} = category <- fetch(Category, scope, company_id, category_id) do
      category
      |> Ecto.Changeset.change(active: active)
      |> Repo.update()
      |> map_result(&Map.take(&1, @category_fields))
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def claim_types(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(ClaimType, scope, company_id)
       |> order_by([t], asc: t.name, asc: t.id)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @type_fields))}
    end
  end

  def create_claim_type(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- company(scope, company_id),
         %Category{} = category <-
           fetch(Category, scope, company_id, attr_id(attrs, :category_id)) do
      %ClaimType{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        category_id: category.id
      }
      |> ClaimType.changeset(attrs)
      |> Repo.insert()
      |> map_result(&Map.take(&1, @type_fields))
    else
      nil -> {:error, :category_not_found}
      error -> error
    end
  end

  def set_claim_type_active(%Scope{} = scope, company_id, claim_type_id, active)
      when is_boolean(active) do
    with {:ok, _company} <- company(scope, company_id),
         %ClaimType{} = claim_type <- fetch(ClaimType, scope, company_id, claim_type_id) do
      claim_type
      |> Ecto.Changeset.change(active: active)
      |> Repo.update()
      |> map_result(&Map.take(&1, @type_fields))
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Policies

  def policies(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(Policy, scope, company_id)
       |> order_by([p], asc: p.claim_type_id, desc: p.effective_from)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @policy_fields))}
    end
  end

  @doc """
  Adds an effective-dated policy for one claim type.

  Periods of one claim type never overlap. The policy currency must be one of
  the company's claim currencies. A receipt threshold is required when the
  claim type asks for receipts above a threshold and is ignored otherwise.
  """
  def create_policy(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, company} <- company(scope, company_id) do
      transaction(fn ->
        with %ClaimType{} = claim_type <-
               lock_claim_type(scope, company_id, attr_id(attrs, :claim_type_id)),
             changeset =
               %Policy{
                 tenant_id: Scope.tenant_id(scope),
                 company_id: company_id,
                 claim_type_id: claim_type.id
               }
               |> Policy.changeset(attrs, company_currencies(company))
               |> receipt_threshold_rule(claim_type),
             {:ok, policy} <- Ecto.Changeset.apply_action(changeset, :insert),
             :ok <- no_overlap(scope, company_id, policy) do
          changeset |> Repo.insert() |> map_result(&Map.take(&1, @policy_fields))
        else
          nil -> {:error, :claim_type_not_found}
          error -> error
        end
      end)
    end
  end

  @doc """
  Closes an open-ended policy on `effective_to`.

  Refused when a live request under the policy was incurred after that date.
  """
  def end_policy(%Scope{} = scope, company_id, policy_id, effective_to) do
    with {:ok, _company} <- company(scope, company_id),
         %Policy{} = unlocked <- fetch(Policy, scope, company_id, policy_id) do
      transaction(fn ->
        lock_claim_type(scope, company_id, unlocked.claim_type_id)

        policy =
          scoped(Policy, scope, company_id)
          |> where([p], p.id == ^unlocked.id)
          |> Repo.one!()

        with nil <- policy.effective_to,
             changeset = Policy.end_changeset(policy, effective_to),
             {:ok, ended} <- Ecto.Changeset.apply_action(changeset, :update),
             false <- requests_after?(scope, company_id, policy.id, ended.effective_to) do
          changeset |> Repo.update() |> map_result(&Map.take(&1, @policy_fields))
        else
          %Date{} -> {:error, :already_ended}
          true -> {:error, :requests_after_end}
          error -> error
        end
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Self-service

  @doc """
  The working employee linked to a login actor in one company.

  A login actor is not an employee: only a Core User record linked to a Core
  Employee in the same company, visible through the workforce seam as
  current, resolves.
  """
  def self_service_employee(%Scope{} = scope, company_id, user_id)
      when is_integer(user_id) and user_id > 0 do
    with {:ok, %{employee_id: employee_id}} when is_integer(employee_id) <-
           User.get_user(scope, company_id, user_id),
         {:ok, result} <- Workforce.employee(scope, company_id, employee_id),
         {:ok, employee} <- ReadResult.require_current(result) do
      {:ok,
       %{
         id: employee_id,
         display_name: employee.display_name,
         employee_number: employee.employee_number
       }}
    else
      _ -> {:error, :not_linked}
    end
  end

  def self_service_employee(%Scope{}, _company_id, _user_id), do: {:error, :not_linked}

  @doc """
  Claim types an employee can claim against on `on_date` (default: today in
  the company time zone), each with the policy in effect on that date.
  """
  def open_claim_types(%Scope{} = scope, company_id, on_date \\ nil) do
    with {:ok, company} <- company(scope, company_id) do
      on_date = on_date || company_today(company)

      {:ok,
       from(t in Tenancy.scope_query(ClaimType, scope),
         join: c in Category,
         on: c.id == t.category_id,
         join: p in Policy,
         on: p.claim_type_id == t.id,
         where: t.company_id == ^company_id and t.active and c.active,
         where: p.effective_from <= ^on_date,
         where: is_nil(p.effective_to) or p.effective_to >= ^on_date,
         order_by: [asc: c.name, asc: t.name, asc: t.id],
         select: {t, c.name, p}
       )
       |> Repo.all()
       |> Enum.map(fn {claim_type, category_name, policy} ->
         claim_type
         |> Map.take(@type_fields)
         |> Map.put(:category_name, category_name)
         |> Map.put(:policy, Map.take(policy, @policy_fields))
       end)}
    end
  end

  ## Requests

  def employee_requests(%Scope{} = scope, company_id, employee_id) do
    with :ok <- employee_exists(scope, company_id, employee_id) do
      {:ok,
       scoped(Request, scope, company_id)
       |> where([r], r.employee_id == ^employee_id)
       |> order_by([r], desc: r.incurred_on, desc: r.id)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @request_fields))}
    end
  end

  def request_events(%Scope{} = scope, company_id, employee_id, request_id) do
    with :ok <- employee_exists(scope, company_id, employee_id),
         %Request{} = request <- fetch(Request, scope, company_id, request_id),
         true <- request.employee_id == employee_id do
      {:ok,
       scoped(RequestEvent, scope, company_id)
       |> where([e], e.request_id == ^request.id)
       |> order_by([e], asc: e.id)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, [:from_status, :to_status, :actor_id, :occurred_at]))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Submits one claim for a working employee.

  Refusals: `:employee_unavailable`, `:claim_type_unavailable`,
  `:future_incurred_on`, `:no_effective_policy`, `:currency_not_allowed`,
  `:receipt_required`, `:per_claim_limit_exceeded`, `:monthly_limit_exceeded`,
  `:yearly_limit_exceeded`, `:duplicate_receipt`, and `:possible_duplicate`.
  The last is a claim of the same type, date, amount, and currency; the
  submitter may confirm it with `confirm_duplicate`, which is recorded.
  """
  def submit_request(%Scope{} = scope, company_id, employee_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    with {:ok, company} <- company(scope, company_id),
         :ok <- working_employee(scope, company_id, employee_id) do
      with_employee_lock(scope, company_id, employee_id, fn ->
        changeset =
          %Request{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            employee_id: employee_id,
            status: "submitted",
            submitted_by_actor_id: actor_id
          }
          |> Request.submission_changeset(attrs)

        with {:ok, input} <- Ecto.Changeset.apply_action(changeset, :insert),
             %ClaimType{} = claim_type <- open_claim_type(scope, company_id, input.claim_type_id),
             :ok <- not_future(input.incurred_on, company),
             %Policy{} = policy <-
               effective_policy(scope, company_id, claim_type.id, input.incurred_on),
             :ok <- currency_allowed(input.currency, policy, company),
             :ok <- receipt_present(claim_type, policy, input),
             :ok <- within_limits(scope, input, policy),
             {:ok, duplicate_confirmed} <- duplicate_check(scope, input),
             {:ok, request} <-
               changeset
               |> Ecto.Changeset.put_change(:claim_policy_id, policy.id)
               |> Ecto.Changeset.put_change(:duplicate_confirmed, duplicate_confirmed)
               |> Ecto.Changeset.put_change(:submitted_at, now())
               |> Repo.insert(),
             {:ok, _event} <- record_event(request, nil, actor_id) do
          {:ok, Map.take(request, @request_fields)}
        else
          {:claim_type, nil} -> {:error, :claim_type_unavailable}
          {:policy, nil} -> {:error, :no_effective_policy}
          error -> error
        end
      end)
    end
  end

  @doc "Withdraws the employee's own submitted claim; history is kept."
  def withdraw_request(%Scope{} = scope, company_id, employee_id, request_id, actor_id)
      when is_integer(actor_id) and actor_id > 0 do
    with_employee_lock(scope, company_id, employee_id, fn ->
      request =
        if is_integer(request_id) do
          scoped(Request, scope, company_id)
          |> where([r], r.id == ^request_id and r.employee_id == ^employee_id)
          |> lock("FOR UPDATE")
          |> Repo.one()
        end

      case request do
        %Request{status: "submitted"} = submitted ->
          with {:ok, withdrawn} <-
                 submitted |> Request.withdraw_changeset(actor_id, now()) |> Repo.update(),
               {:ok, _event} <- record_event(withdrawn, "submitted", actor_id) do
            {:ok, Map.take(withdrawn, @request_fields)}
          end

        %Request{} ->
          {:error, :not_withdrawable}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  ## Submission rules

  defp open_claim_type(scope, company_id, claim_type_id) do
    from(t in Tenancy.scope_query(ClaimType, scope),
      join: c in Category,
      on: c.id == t.category_id,
      where: t.company_id == ^company_id and t.id == ^claim_type_id and t.active and c.active
    )
    |> Repo.one()
    |> tag(:claim_type)
  end

  defp effective_policy(scope, company_id, claim_type_id, on_date) do
    scoped(Policy, scope, company_id)
    |> where([p], p.claim_type_id == ^claim_type_id and p.effective_from <= ^on_date)
    |> where([p], is_nil(p.effective_to) or p.effective_to >= ^on_date)
    |> Repo.one()
    |> tag(:policy)
  end

  defp tag(nil, kind), do: {kind, nil}
  defp tag(record, _kind), do: record

  defp not_future(incurred_on, company) do
    if Date.compare(incurred_on, company_today(company)) == :gt,
      do: {:error, :future_incurred_on},
      else: :ok
  end

  defp currency_allowed(currency, %Policy{currency: currency}, company) do
    if currency in company_currencies(company), do: :ok, else: {:error, :currency_not_allowed}
  end

  defp currency_allowed(_currency, _policy, _company), do: {:error, :currency_not_allowed}

  defp receipt_present(claim_type, policy, input) do
    required? =
      case claim_type.receipt_requirement do
        "always" -> true
        "never" -> false
        "above_threshold" -> Decimal.gt?(input.amount, policy.receipt_threshold)
      end

    if required? and is_nil(input.receipt_number),
      do: {:error, :receipt_required},
      else: :ok
  end

  defp within_limits(scope, input, policy) do
    month = Date.beginning_of_month(input.incurred_on)
    year = Date.new!(input.incurred_on.year, 1, 1)

    cond do
      exceeds?(policy.per_claim_limit, input.amount) ->
        {:error, :per_claim_limit_exceeded}

      exceeds?(
        policy.monthly_limit,
        Decimal.add(used(scope, input, month, Date.end_of_month(month)), input.amount)
      ) ->
        {:error, :monthly_limit_exceeded}

      exceeds?(
        policy.yearly_limit,
        Decimal.add(used(scope, input, year, Date.new!(year.year, 12, 31)), input.amount)
      ) ->
        {:error, :yearly_limit_exceeded}

      true ->
        :ok
    end
  end

  defp exceeds?(nil, _amount), do: false
  defp exceeds?(limit, amount), do: Decimal.gt?(amount, limit)

  # Every live request of the type and currency counts toward the period,
  # whatever policy was in effect when it was incurred.
  defp used(scope, input, first, last) do
    live_requests(scope, input)
    |> where([r], r.incurred_on >= ^first and r.incurred_on <= ^last)
    |> select([r], coalesce(sum(r.amount), 0))
    |> Repo.one()
    |> Decimal.new()
  end

  defp duplicate_check(scope, input) do
    receipt_taken? =
      not is_nil(input.receipt_number) and
        live_requests(scope, input)
        |> where([r], r.receipt_number == ^input.receipt_number)
        |> Repo.exists?()

    same_shape? =
      live_requests(scope, input)
      |> where([r], r.incurred_on == ^input.incurred_on and r.amount == ^input.amount)
      |> Repo.exists?()

    cond do
      receipt_taken? -> {:error, :duplicate_receipt}
      same_shape? and input.confirm_duplicate -> {:ok, true}
      same_shape? -> {:error, :possible_duplicate}
      true -> {:ok, false}
    end
  end

  defp live_requests(scope, input) do
    scoped(Request, scope, input.company_id)
    |> where([r], r.employee_id == ^input.employee_id and r.claim_type_id == ^input.claim_type_id)
    |> where([r], r.currency == ^input.currency and r.status != "withdrawn")
  end

  defp record_event(request, from_status, actor_id) do
    Repo.insert(%RequestEvent{
      tenant_id: request.tenant_id,
      company_id: request.company_id,
      request_id: request.id,
      from_status: from_status,
      to_status: request.status,
      actor_id: actor_id,
      occurred_at: now()
    })
  end

  ## Policy rules

  defp receipt_threshold_rule(changeset, %ClaimType{receipt_requirement: "above_threshold"}),
    do: Ecto.Changeset.validate_required(changeset, [:receipt_threshold])

  defp receipt_threshold_rule(changeset, _claim_type),
    do: Ecto.Changeset.put_change(changeset, :receipt_threshold, nil)

  defp no_overlap(scope, company_id, policy) do
    query =
      scoped(Policy, scope, company_id)
      |> where([p], p.claim_type_id == ^policy.claim_type_id)
      |> where([p], is_nil(p.effective_to) or p.effective_to >= ^policy.effective_from)

    query =
      if policy.effective_to,
        do: where(query, [p], p.effective_from <= ^policy.effective_to),
        else: query

    if Repo.exists?(query), do: {:error, :overlapping_policy}, else: :ok
  end

  defp requests_after?(scope, company_id, policy_id, effective_to) do
    scoped(Request, scope, company_id)
    |> where([r], r.claim_policy_id == ^policy_id and r.status != "withdrawn")
    |> where([r], r.incurred_on > ^effective_to)
    |> Repo.exists?()
  end

  defp lock_claim_type(scope, company_id, claim_type_id) when is_integer(claim_type_id) do
    scoped(ClaimType, scope, company_id)
    |> where([t], t.id == ^claim_type_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_claim_type(_scope, _company_id, _claim_type_id), do: nil

  ## Company, employee, and settings

  defp company(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, company} -> {:ok, company}
      _ -> {:error, :not_found}
    end
  end

  defp company_currencies(company) do
    case Settings.get(@currencies_key, settings_scope(company)) do
      codes when is_list(codes) -> codes
      _ -> []
    end
  end

  defp settings_scope(company), do: SettingsScope.company(company.id, company.tenant_id)

  defp company_today(company) do
    timezone = BaseDateTime.company_timezone(settings_scope(company))

    case DateTime.now(timezone, BaseDateTime.time_zone_database()) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _reason} -> Date.utc_today()
    end
  end

  defp normalize_currencies(codes) when is_list(codes) and length(codes) <= @max_currencies do
    normalized =
      Enum.map(codes, fn
        code when is_binary(code) -> code |> String.trim() |> String.upcase()
        _ -> nil
      end)

    if Enum.all?(normalized, &(is_binary(&1) and &1 =~ ~r/^[A-Z]{3}$/)),
      do: {:ok, Enum.uniq(normalized)},
      else: {:error, :invalid_currencies}
  end

  defp normalize_currencies(_codes), do: {:error, :invalid_currencies}

  defp working_employee(scope, company_id, employee_id) when is_integer(employee_id) do
    with {:ok, result} <- Workforce.employee(scope, company_id, employee_id),
         {:ok, _employee} <- ReadResult.require_current(result) do
      :ok
    else
      _ -> {:error, :employee_unavailable}
    end
  end

  defp working_employee(_scope, _company_id, _employee_id), do: {:error, :employee_unavailable}

  defp employee_exists(scope, company_id, employee_id) do
    with {:ok, _company} <- company(scope, company_id),
         {:ok, _employee} <- Employee.get_employee(scope, company_id, employee_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp with_employee_lock(scope, company_id, employee_id, fun) do
    transaction(fn ->
      case Employee.lock_affiliation(scope, company_id, employee_id) do
        {:ok, _proof} -> fun.()
        _ -> {:error, :not_found}
      end
    end)
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  ## Helpers

  defp scoped(schema, scope, company_id),
    do: from(row in Tenancy.scope_query(schema, scope), where: row.company_id == ^company_id)

  defp fetch(schema, scope, company_id, id) when is_integer(id) do
    scoped(schema, scope, company_id) |> where([row], row.id == ^id) |> Repo.one()
  end

  defp fetch(_schema, _scope, _company_id, _id), do: nil

  defp attr_id(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      id when is_integer(id) and id > 0 ->
        id

      raw when is_binary(raw) ->
        case Integer.parse(raw) do
          {id, ""} when id > 0 -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp map_result({:ok, record}, fun), do: {:ok, fun.(record)}
  defp map_result(error, _fun), do: error

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
