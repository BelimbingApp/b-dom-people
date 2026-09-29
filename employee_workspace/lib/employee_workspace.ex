defmodule Bilimbi.People.EmployeeWorkspace do
  @moduledoc """
  Company-scoped People facts around Core Employee identity.

  Employee master fields remain in Core. A change request records a proposal
  and review decision; approval does not silently write to Core Employee.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.EmployeeWorkspace.{Access, ChangeRequest, SavedView, WorkProfile}

  def employees(%Scope{} = scope, company_id) do
    with :ok <- company_exists(scope, company_id), do: Employee.list_employees(scope, company_id)
  end

  def employee(%Scope{} = scope, company_id, employee_id),
    do: Employee.get_employee(scope, company_id, employee_id)

  def work_profile(%Scope{} = scope, company_id, employee_id) do
    with :ok <- employee_exists(scope, company_id, employee_id) do
      {:ok,
       scoped(WorkProfile, scope, company_id)
       |> where([p], p.employee_id == ^employee_id)
       |> Repo.one()
       |> public_record([:work_location, :work_arrangement, :notes])}
    end
  end

  def put_work_profile(%Scope{} = scope, company_id, employee_id, attrs)
      when is_map(attrs) do
    with_employee_lock(scope, company_id, employee_id, fn ->
      record =
        scoped(WorkProfile, scope, company_id)
        |> where([p], p.employee_id == ^employee_id)
        |> Repo.one() ||
          %WorkProfile{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            employee_id: employee_id
          }

      record
      |> WorkProfile.changeset(attrs)
      |> save(record)
      |> map_result(&public_record(&1, [:work_location, :work_arrangement, :notes]))
    end)
  end

  def access(%Scope{} = scope, company_id, employee_id) do
    with :ok <- employee_exists(scope, company_id, employee_id) do
      {:ok,
       scoped(Access, scope, company_id)
       |> where([a], a.employee_id == ^employee_id)
       |> Repo.one()
       |> public_record([:portal_enabled, :reason])}
    end
  end

  def put_access(%Scope{} = scope, company_id, employee_id, attrs) when is_map(attrs) do
    with_employee_lock(scope, company_id, employee_id, fn ->
      record =
        scoped(Access, scope, company_id)
        |> where([a], a.employee_id == ^employee_id)
        |> Repo.one() ||
          %Access{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            employee_id: employee_id
          }

      record
      |> Access.changeset(attrs)
      |> save(record)
      |> map_result(&public_record(&1, [:portal_enabled, :reason]))
    end)
  end

  def change_requests(%Scope{} = scope, company_id, employee_id) do
    with :ok <- employee_exists(scope, company_id, employee_id) do
      {:ok,
       scoped(ChangeRequest, scope, company_id)
       |> where([r], r.employee_id == ^employee_id)
       |> order_by([r], desc: r.id)
       |> Repo.all()
       |> Enum.map(&public_record(&1, request_fields()))}
    end
  end

  def request_change(%Scope{} = scope, company_id, employee_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    with_employee_lock(scope, company_id, employee_id, fn ->
      %ChangeRequest{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        employee_id: employee_id,
        requested_by_actor_id: actor_id
      }
      |> ChangeRequest.changeset(attrs)
      |> Repo.insert()
      |> map_result(&public_record(&1, request_fields()))
    end)
  end

  def review_change(%Scope{} = scope, company_id, employee_id, request_id, actor_id, status)
      when is_integer(request_id) and request_id > 0 and is_integer(actor_id) and
             actor_id > 0 and status in ["approved", "rejected"] do
    with_employee_lock(scope, company_id, employee_id, fn ->
      record =
        scoped(ChangeRequest, scope, company_id)
        |> where([r], r.id == ^request_id and r.employee_id == ^employee_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case record do
        %ChangeRequest{status: "pending"} = pending ->
          pending
          |> ChangeRequest.review_changeset(status, actor_id)
          |> Repo.update()
          |> map_result(&public_record(&1, request_fields()))

        %ChangeRequest{} ->
          {:error, :already_reviewed}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  def review_change(%Scope{}, _, _, _, _, _), do: {:error, :invalid_review}

  def saved_views(%Scope{} = scope, company_id, actor_id)
      when is_integer(actor_id) and actor_id > 0 do
    with :ok <- company_exists(scope, company_id) do
      {:ok,
       scoped(SavedView, scope, company_id)
       |> where([v], v.actor_id == ^actor_id)
       |> order_by([v], asc: v.name)
       |> Repo.all()
       |> Enum.map(&public_record(&1, [:id, :name, :search, :status]))}
    end
  end

  def save_view(%Scope{} = scope, company_id, actor_id, attrs)
      when is_integer(actor_id) and actor_id > 0 and is_map(attrs) do
    with :ok <- company_exists(scope, company_id) do
      %SavedView{tenant_id: Scope.tenant_id(scope), company_id: company_id, actor_id: actor_id}
      |> SavedView.changeset(attrs)
      |> Repo.insert()
      |> map_result(&public_record(&1, [:id, :name, :search, :status]))
    end
  end

  def delete_view(%Scope{} = scope, company_id, actor_id, view_id)
      when is_integer(actor_id) and actor_id > 0 and is_integer(view_id) and view_id > 0 do
    with :ok <- company_exists(scope, company_id),
         %SavedView{} = record <-
           scoped(SavedView, scope, company_id)
           |> where([v], v.actor_id == ^actor_id and v.id == ^view_id)
           |> Repo.one() do
      Repo.delete(record) |> map_result(fn _ -> :deleted end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp request_fields,
    do: [
      :id,
      :field,
      :proposed_value,
      :reason,
      :status,
      :requested_by_actor_id,
      :reviewed_by_actor_id,
      :reviewed_at,
      :inserted_at
    ]

  defp scoped(schema, scope, company_id),
    do: from(row in Tenancy.scope_query(schema, scope), where: row.company_id == ^company_id)

  defp public_record(nil, _fields), do: nil
  defp public_record(record, fields), do: Map.take(record, fields)

  defp map_result({:ok, record}, fun), do: {:ok, fun.(record)}
  defp map_result(error, _fun), do: error

  defp save(changeset, %{__meta__: %Ecto.Schema.Metadata{state: :loaded}}),
    do: Repo.update(changeset)

  defp save(changeset, _record), do: Repo.insert(changeset)

  defp company_exists(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, _company} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp employee_exists(scope, company_id, employee_id) do
    with :ok <- company_exists(scope, company_id),
         {:ok, _employee} <- Employee.get_employee(scope, company_id, employee_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp with_employee_lock(scope, company_id, employee_id, fun) do
    case Repo.transaction(fn ->
           case Employee.lock_affiliation(scope, company_id, employee_id) do
             {:ok, _proof} ->
               case fun.() do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end

             _ ->
               Repo.rollback(:not_found)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
