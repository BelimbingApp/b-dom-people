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

  alias Bilimbi.People.Claims.{
    Assignment,
    AssignmentEmployee,
    AssignmentType,
    Category,
    ClaimType,
    Csv,
    HandoffBatch,
    Policy,
    Request,
    RequestEvent
  }

  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult

  @currencies_key "people.claims.currencies"
  @max_currencies 20

  @category_fields [:id, :code, :name, :active]
  @type_fields [:id, :category_id, :code, :name, :receipt_requirement, :eligibility, :active]
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
    :withdrawn_at,
    :approved_amount,
    :decided_by_actor_id,
    :decided_at,
    :decision_reason,
    :reimbursed_by_actor_id,
    :reimbursed_at,
    :payment_reference,
    :handoff_batch_id
  ]
  @assignment_fields [:id, :code, :name, :effective_from, :effective_to]
  @batch_fields [:id, :currency, :request_count, :total_amount, :created_by_actor_id, :created_at]

  # A withdrawn or rejected claim stops counting toward limits and releases
  # its receipt reference; every other status is live.
  @dead_statuses ["withdrawn", "rejected"]
  @queue_statuses ~w(submitted approved rejected reimbursed)
  @queue_limit 500
  @export_headers ~w(
    batch_id claim_id employee_number employee_name category claim_type_code
    claim_type_name incurred_on currency claimed_amount approved_amount
    receipt_number description status approved_at reimbursed_at payment_reference
  )

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

  @doc "IDs of claim types with a claim incurred in `from`..`to` that is not withdrawn or rejected."
  def requested_claim_type_ids(%Scope{} = scope, company_id, %Date{} = from, %Date{} = to) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(Request, scope, company_id)
       |> where(
         [r],
         r.status not in ["withdrawn", "rejected"] and r.incurred_on >= ^from and
           r.incurred_on <= ^to
       )
       |> distinct(true)
       |> select([r], r.claim_type_id)
       |> Repo.all()}
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
          |> lock("FOR UPDATE")
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
  Claim types open for claims on `on_date` (default: today in the company
  time zone), each with the policy in effect on that date.

  With `employee_id:`, assigned-only types appear only when an assignment in
  effect on `on_date` covers the type and the employee. Without it, every
  open type appears.
  """
  def open_claim_types(%Scope{} = scope, company_id, on_date \\ nil, opts \\ []) do
    with {:ok, company} <- company(scope, company_id) do
      on_date = on_date || company_today(company)

      query =
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

      query =
        case Keyword.fetch(opts, :employee_id) do
          {:ok, employee_id} ->
            assigned = assigned_type_ids(scope, company_id, employee_id, on_date)
            where(query, [t], t.eligibility == "all_employees" or t.id in ^assigned)

          :error ->
            query
        end

      {:ok,
       query
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
       |> Enum.map(&Map.take(&1, [:from_status, :to_status, :actor_id, :reason, :occurred_at]))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Submits one claim for a working employee.

  Refusals: `:employee_unavailable`, `:claim_type_unavailable`,
  `:claim_type_not_assigned`, `:future_incurred_on`, `:no_effective_policy`, `:currency_not_allowed`,
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
             :ok <- assigned(scope, company_id, claim_type, input),
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

  ## Assignments

  @doc """
  Assignments with the claim types they open and the employees they cover.
  """
  def assignments(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      assignments =
        scoped(Assignment, scope, company_id)
        |> order_by([a], asc: a.name, asc: a.id)
        |> Repo.all()

      ids = Enum.map(assignments, & &1.id)
      types = member_ids(scope, company_id, AssignmentType, :claim_type_id, ids)
      employees = member_ids(scope, company_id, AssignmentEmployee, :employee_id, ids)

      {:ok,
       Enum.map(assignments, fn assignment ->
         assignment
         |> Map.take(@assignment_fields)
         |> Map.put(:claim_type_ids, Map.get(types, assignment.id, []))
         |> Map.put(:employee_ids, Map.get(employees, assignment.id, []))
       end)}
    end
  end

  @doc """
  Adds an effective-dated assignment. Members are set separately with
  `set_assignment_members/5`.
  """
  def create_assignment(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, _company} <- company(scope, company_id) do
      %Assignment{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Assignment.changeset(attrs)
      |> Repo.insert()
      |> map_result(&Map.take(&1, @assignment_fields))
    end
  end

  @doc "Closes an open-ended assignment on `effective_to`."
  def end_assignment(%Scope{} = scope, company_id, assignment_id, effective_to) do
    with {:ok, _company} <- company(scope, company_id) do
      transaction(fn ->
        with %Assignment{effective_to: nil} = assignment <-
               lock_assignment(scope, company_id, assignment_id),
             {:ok, ended} <-
               assignment |> Assignment.end_changeset(effective_to) |> Repo.update() do
          {:ok, Map.take(ended, @assignment_fields)}
        else
          %Assignment{} -> {:error, :already_ended}
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  @doc """
  Replaces the claim types an assignment opens and the employees it covers,
  together. Every claim type and employee must belong to the company;
  working status is judged when a claim is submitted.
  """
  def set_assignment_members(%Scope{} = scope, company_id, assignment_id, type_ids, employee_ids)
      when is_list(type_ids) and is_list(employee_ids) do
    with {:ok, _company} <- company(scope, company_id),
         {:ok, type_ids} <- normalize_ids(type_ids, :claim_type_not_found),
         {:ok, employee_ids} <- normalize_ids(employee_ids, :employee_not_found),
         :ok <- company_employees(scope, company_id, employee_ids) do
      transaction(fn ->
        with %Assignment{} = assignment <- lock_assignment(scope, company_id, assignment_id),
             :ok <-
               all_in_company(scope, company_id, ClaimType, type_ids, :claim_type_not_found),
             {:ok, type_ids} <-
               replace_members(assignment, AssignmentType, :claim_type_id, type_ids),
             {:ok, employee_ids} <-
               replace_members(assignment, AssignmentEmployee, :employee_id, employee_ids) do
          {:ok, %{claim_type_ids: type_ids, employee_ids: employee_ids}}
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  @doc "Employees of the company an assignment may cover, by employee number."
  def assignable_employees(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id),
         {:ok, employees} <- Employee.list_employees(scope, company_id) do
      {:ok,
       employees
       |> Enum.map(&%{id: &1.id, employee_number: &1.employee_number, name: &1.full_name})
       |> Enum.sort_by(&{&1.employee_number, &1.id})}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Decisions and reimbursement

  @doc """
  Operator queue of one status, newest decision context first: submitted
  claims oldest first, every other status newest first. At most 500 rows.
  """
  def claim_queue(%Scope{} = scope, company_id, status) when status in @queue_statuses do
    with {:ok, _company} <- company(scope, company_id) do
      order = if status == "submitted", do: [asc: :id], else: [desc: :id]

      requests =
        scoped(Request, scope, company_id)
        |> where([r], r.status == ^status)
        |> order_by(^order)
        |> limit(@queue_limit)
        |> Repo.all()

      employees = employee_index(scope, Enum.map(requests, & &1.employee_id))
      types = catalog_index(scope, company_id)

      {:ok,
       Enum.map(requests, fn request ->
         request
         |> Map.take(@request_fields)
         |> Map.merge(employee_columns(employees, request.employee_id))
         |> Map.merge(type_columns(types, request.claim_type_id))
       end)}
    end
  end

  @doc """
  Approved claims that no hand-off batch holds yet, per currency, as
  `{currency, count, total_approved_amount}` sorted by currency.
  """
  def handoff_waiting(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(Request, scope, company_id)
       |> where([r], r.status == "approved" and is_nil(r.handoff_batch_id))
       |> group_by([r], r.currency)
       |> order_by([r], asc: r.currency)
       |> select([r], {r.currency, count(r.id), sum(r.approved_amount)})
       |> Repo.all()}
    end
  end

  @doc """
  Approves a submitted claim, in full unless `approved_amount` is lower; a
  lower amount needs a `decision_reason`.

  Refusals: `:not_found`, `:not_decidable` (not submitted), `:own_claim`, and
  a changeset for invalid amounts. The decision and its history row are one
  transaction.
  """
  def approve_request(%Scope{} = scope, company_id, request_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    decide(scope, company_id, request_id, actor_id, "submitted", fn request, now ->
      Request.approval_changeset(request, attrs, actor_id, now)
    end)
  end

  @doc "Rejects a submitted claim; a `decision_reason` is required."
  def reject_request(%Scope{} = scope, company_id, request_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    decide(scope, company_id, request_id, actor_id, "submitted", fn request, now ->
      Request.rejection_changeset(request, attrs, actor_id, now)
    end)
  end

  @doc """
  Records that an approved claim was paid, with an optional
  `payment_reference`. Refused for claims that are not approved or are the
  actor's own.
  """
  def reimburse_request(%Scope{} = scope, company_id, request_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    decide(scope, company_id, request_id, actor_id, "approved", fn request, now ->
      Request.reimbursement_changeset(request, attrs, actor_id, now)
    end)
  end

  @doc """
  Hands off every approved claim in `currency` that is not yet in a batch.

  The batch is an immutable record of who handed off which claims and when;
  claims of different currencies never share a batch. Refused with
  `:nothing_to_hand_off` when none qualifies.
  """
  def create_handoff_batch(%Scope{} = scope, company_id, currency, actor_id)
      when is_binary(currency) and is_integer(actor_id) and actor_id > 0 do
    with {:ok, _company} <- company(scope, company_id),
         {:ok, [currency]} <- handoff_currency(currency) do
      transaction(fn ->
        requests =
          scoped(Request, scope, company_id)
          |> where([r], r.status == "approved" and is_nil(r.handoff_batch_id))
          |> where([r], r.currency == ^currency)
          |> order_by([r], asc: r.id)
          |> lock("FOR UPDATE")
          |> Repo.all()

        if requests == [] do
          {:error, :nothing_to_hand_off}
        else
          total = Enum.reduce(requests, Decimal.new(0), &Decimal.add(&2, &1.approved_amount))

          {:ok, batch} =
            Repo.insert(%HandoffBatch{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              currency: currency,
              request_count: length(requests),
              total_amount: total,
              created_by_actor_id: actor_id,
              created_at: now()
            })

          ids = Enum.map(requests, & &1.id)

          scoped(Request, scope, company_id)
          |> where([r], r.id in ^ids)
          |> Repo.update_all(set: [handoff_batch_id: batch.id, updated_at: now()])

          {:ok, Map.take(batch, @batch_fields)}
        end
      end)
    end
  end

  def handoff_batches(%Scope{} = scope, company_id) do
    with {:ok, _company} <- company(scope, company_id) do
      {:ok,
       scoped(HandoffBatch, scope, company_id)
       |> order_by([b], desc: b.id)
       |> limit(@queue_limit)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @batch_fields))}
    end
  end

  @doc """
  CSV of one hand-off batch: one row per claim with its current status,
  built from the stored facts. Returns `%{filename: _, content: _}`.
  """
  def handoff_export(%Scope{} = scope, company_id, batch_id) do
    with {:ok, _company} <- company(scope, company_id),
         %HandoffBatch{} = batch <- fetch(HandoffBatch, scope, company_id, batch_id) do
      requests =
        scoped(Request, scope, company_id)
        |> where([r], r.handoff_batch_id == ^batch.id)
        |> order_by([r], asc: r.id)
        |> Repo.all()

      employees = employee_index(scope, Enum.map(requests, & &1.employee_id))
      types = catalog_index(scope, company_id)

      rows =
        Enum.map(requests, fn request ->
          employee = employee_columns(employees, request.employee_id)
          type = type_columns(types, request.claim_type_id)

          [
            batch.id,
            request.id,
            employee.employee_number,
            employee.employee_name,
            type.category_name,
            type.claim_type_code,
            type.claim_type_name,
            request.incurred_on,
            request.currency,
            request.amount,
            request.approved_amount,
            request.receipt_number,
            request.description,
            request.status,
            request.decided_at,
            request.reimbursed_at,
            request.payment_reference
          ]
        end)

      {:ok,
       %{
         filename: "claim-handoff-#{batch.id}.csv",
         content: Csv.encode(@export_headers, rows)
       }}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Marks every still-approved claim of a hand-off batch reimbursed. Refused
  with `:own_claim` when the actor's own claim is among them.
  """
  def reimburse_batch(%Scope{} = scope, company_id, batch_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    with {:ok, _company} <- company(scope, company_id),
         %HandoffBatch{} = batch <- fetch(HandoffBatch, scope, company_id, batch_id) do
      transaction(fn ->
        requests =
          scoped(Request, scope, company_id)
          |> where([r], r.handoff_batch_id == ^batch.id and r.status == "approved")
          |> order_by([r], asc: r.id)
          |> lock("FOR UPDATE")
          |> Repo.all()

        with [_ | _] <- requests,
             :ok <- Enum.find_value(requests, :ok, &own_claim_error(scope, &1, actor_id)),
             {:ok, done} <- reimburse_all(requests, attrs, actor_id) do
          {:ok, done}
        else
          [] -> {:error, :nothing_to_reimburse}
          error -> error
        end
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  ## Submission rules

  defp assigned(_scope, _company_id, %ClaimType{eligibility: "all_employees"}, _input), do: :ok

  defp assigned(scope, company_id, %ClaimType{} = claim_type, input) do
    if claim_type.id in assigned_type_ids(scope, company_id, input.employee_id, input.incurred_on),
      do: :ok,
      else: {:error, :claim_type_not_assigned}
  end

  defp assigned_type_ids(scope, company_id, employee_id, on_date) do
    from(a in Tenancy.scope_query(Assignment, scope),
      join: at in AssignmentType,
      on: at.assignment_id == a.id,
      join: ae in AssignmentEmployee,
      on: ae.assignment_id == a.id,
      where: a.company_id == ^company_id and ae.employee_id == ^employee_id,
      where: a.effective_from <= ^on_date,
      where: is_nil(a.effective_to) or a.effective_to >= ^on_date,
      distinct: true,
      select: at.claim_type_id
    )
    |> Repo.all()
  end

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
    |> lock("FOR SHARE")
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
  # whatever policy was in effect when it was incurred. An approval for less
  # than the claim counts for what was approved.
  defp used(scope, input, first, last) do
    live_requests(scope, input)
    |> where([r], r.incurred_on >= ^first and r.incurred_on <= ^last)
    |> select([r], coalesce(sum(coalesce(r.approved_amount, r.amount)), 0))
    |> Repo.one()
    |> Decimal.new()
  end

  defp duplicate_check(scope, input) do
    receipt_taken? =
      not is_nil(input.receipt_number) and
        scoped(Request, scope, input.company_id)
        |> where([r], r.employee_id == ^input.employee_id and r.status not in ^@dead_statuses)
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
    |> where([r], r.currency == ^input.currency and r.status not in ^@dead_statuses)
  end

  defp record_event(request, from_status, actor_id, reason \\ nil) do
    Repo.insert(%RequestEvent{
      tenant_id: request.tenant_id,
      company_id: request.company_id,
      request_id: request.id,
      from_status: from_status,
      to_status: request.status,
      actor_id: actor_id,
      reason: reason,
      occurred_at: now()
    })
  end

  ## Decision rules

  defp handoff_currency(currency) do
    case normalize_currencies([currency]) do
      {:ok, [_code]} = ok -> ok
      {:error, :invalid_currencies} -> {:error, :invalid_currency}
    end
  end

  defp decide(scope, company_id, request_id, actor_id, from_status, build_changeset) do
    with {:ok, _company} <- company(scope, company_id) do
      transaction(fn ->
        with %Request{status: ^from_status} = request <-
               lock_request(scope, company_id, request_id),
             :ok <- own_claim_error(scope, request, actor_id) || :ok,
             {:ok, updated} <- request |> build_changeset.(now()) |> Repo.update(),
             reason = if(from_status == "submitted", do: updated.decision_reason),
             {:ok, _event} <- record_event(updated, from_status, actor_id, reason) do
          {:ok, Map.take(updated, @request_fields)}
        else
          %Request{} -> {:error, :not_decidable}
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  defp reimburse_all(requests, attrs, actor_id) do
    Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, done} ->
      moment = now()

      with {:ok, updated} <-
             request |> Request.reimbursement_changeset(attrs, actor_id, moment) |> Repo.update(),
           {:ok, _event} <- record_event(updated, "approved", actor_id) do
        {:cont, {:ok, [Map.take(updated, @request_fields) | done]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp lock_request(scope, company_id, request_id) when is_integer(request_id) do
    scoped(Request, scope, company_id)
    |> where([r], r.id == ^request_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_request(_scope, _company_id, _request_id), do: nil

  # Separation of duties: a login actor never decides or pays a claim it
  # submitted, nor one of the employee it is linked to.
  defp own_claim_error(scope, %Request{} = request, actor_id) do
    linked_employee =
      case User.get_tenant_user(scope, actor_id) do
        {:ok, %{employee_id: employee_id}} -> employee_id
        _ -> nil
      end

    if request.submitted_by_actor_id == actor_id or
         (not is_nil(linked_employee) and linked_employee == request.employee_id),
       do: {:error, :own_claim},
       else: nil
  end

  ## Assignment rules

  defp lock_assignment(scope, company_id, assignment_id) when is_integer(assignment_id) do
    scoped(Assignment, scope, company_id)
    |> where([a], a.id == ^assignment_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_assignment(_scope, _company_id, _assignment_id), do: nil

  defp member_ids(_scope, _company_id, _schema, _field, []), do: %{}

  defp member_ids(scope, company_id, schema, field, assignment_ids) do
    scoped(schema, scope, company_id)
    |> where([m], m.assignment_id in ^assignment_ids)
    |> order_by([m], asc: field(m, ^field))
    |> select([m], {m.assignment_id, field(m, ^field)})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp replace_members(assignment, schema, field, ids) do
    existing =
      from(m in schema, where: m.assignment_id == ^assignment.id)
      |> Repo.all()

    kept = MapSet.new(ids)

    stale = for m <- existing, not MapSet.member?(kept, Map.fetch!(m, field)), do: m.id
    present = MapSet.new(existing, &Map.fetch!(&1, field))

    from(m in schema, where: m.id in ^stale) |> Repo.delete_all()

    Enum.each(ids, fn id ->
      unless MapSet.member?(present, id) do
        Repo.insert!(
          struct!(schema, %{
            tenant_id: assignment.tenant_id,
            company_id: assignment.company_id,
            assignment_id: assignment.id
          })
          |> Map.put(field, id)
        )
      end
    end)

    {:ok, Enum.sort(ids)}
  end

  defp normalize_ids(ids, error) do
    parsed = Enum.map(ids, &attr_id(%{id: &1}, :id))

    if length(ids) <= 1_000 and Enum.all?(parsed, & &1),
      do: {:ok, Enum.uniq(parsed)},
      else: {:error, error}
  end

  defp all_in_company(_scope, _company_id, _schema, [], _error), do: :ok

  defp all_in_company(scope, company_id, schema, ids, error) do
    found =
      scoped(schema, scope, company_id)
      |> where([row], row.id in ^ids)
      |> select([row], count(row.id))
      |> Repo.one()

    if found == length(ids), do: :ok, else: {:error, error}
  end

  defp company_employees(_scope, _company_id, []), do: :ok

  defp company_employees(scope, company_id, ids) do
    {:ok, employees} = Employee.get_tenant_employees(scope, ids)

    if Enum.all?(ids, &match?(%{company_id: ^company_id}, Map.get(employees, &1))),
      do: :ok,
      else: {:error, :employee_not_found}
  end

  ## Queue and export rows

  defp employee_index(_scope, []), do: %{}

  defp employee_index(scope, employee_ids) do
    {:ok, employees} = Employee.get_tenant_employees(scope, Enum.uniq(employee_ids))
    employees
  end

  defp employee_columns(employees, employee_id) do
    case Map.get(employees, employee_id) do
      nil -> %{employee_number: nil, employee_name: nil}
      employee -> %{employee_number: employee.employee_number, employee_name: employee.full_name}
    end
  end

  defp catalog_index(scope, company_id) do
    from(t in Tenancy.scope_query(ClaimType, scope),
      join: c in Category,
      on: c.id == t.category_id,
      where: t.company_id == ^company_id,
      select: {t.id, %{claim_type_code: t.code, claim_type_name: t.name, category_name: c.name}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp type_columns(types, claim_type_id),
    do:
      Map.get(types, claim_type_id, %{
        claim_type_code: nil,
        claim_type_name: nil,
        category_name: nil
      })

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
    |> where([r], r.claim_policy_id == ^policy_id and r.status not in ^@dead_statuses)
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
