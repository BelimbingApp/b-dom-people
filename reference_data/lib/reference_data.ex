defmodule Bilimbi.People.ReferenceData do
  @moduledoc """
  Company-scoped People references and calendar exceptions.

  Reads take a validated scope and an explicit company and are company
  configuration, so Leave and the operator page share them without a grant.
  Every write authorizes `people.references.manage` for the scope's actor
  and the target company at the moment it runs, through
  `Bilimbi.People.Workforce.Authorization`, so a grant revoked while an
  operator page stays open refuses the next write with `:unauthorized`.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.People.ReferenceData.{Alias, CalendarException, Entry}
  alias Bilimbi.People.Workforce.Authorization

  @manage_capability "people.references.manage"

  def list_entries(%Scope{} = scope, company_id) do
    with :ok <- validate_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(e in Tenancy.scope_query(Entry, scope),
           where: e.company_id == ^company_id,
           order_by: [asc: e.kind, asc: e.label, asc: e.id]
         )
       )
       |> Enum.map(&entry_view/1)}
    end
  end

  def create_entry(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with :ok <- authorize_write(scope, company_id) do
      %Entry{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Entry.changeset(attributes)
      |> Repo.insert()
      |> public_result(&entry_view/1)
    end
  end

  def add_alias(%Scope{} = scope, company_id, entry_id, attributes) when is_map(attributes) do
    with :ok <- authorize_write(scope, company_id),
         %Entry{kind: kind} <- entry_in_company(scope, company_id, entry_id) do
      %Alias{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        entry_id: entry_id,
        kind: kind
      }
      |> Alias.changeset(attributes)
      |> Repo.insert()
      |> public_result(&alias_view/1)
    else
      nil -> {:error, :entry_not_found}
      error -> error
    end
  end

  def list_aliases(%Scope{} = scope, company_id) do
    with :ok <- validate_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(a in Tenancy.scope_query(Alias, scope),
           where: a.company_id == ^company_id,
           order_by: [asc: a.entry_id, asc: a.label]
         )
       )
       |> Enum.map(&alias_view/1)}
    end
  end

  def list_calendar_exceptions(%Scope{} = scope, company_id) do
    with :ok <- validate_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(e in Tenancy.scope_query(CalendarException, scope),
           where: e.company_id == ^company_id,
           order_by: [asc: e.on_date, asc: e.id]
         )
       )
       |> Enum.map(&exception_view/1)}
    end
  end

  def create_calendar_exception(%Scope{} = scope, company_id, attributes)
      when is_map(attributes) do
    with :ok <- authorize_write(scope, company_id) do
      %CalendarException{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> CalendarException.changeset(attributes)
      |> Repo.insert()
      |> public_result(&exception_view/1)
    end
  end

  defp entry_in_company(scope, company_id, entry_id) when is_integer(entry_id) do
    Repo.one(
      from(e in Tenancy.scope_query(Entry, scope),
        where: e.id == ^entry_id and e.company_id == ^company_id
      )
    )
  end

  defp entry_in_company(_scope, _company_id, _entry_id), do: nil

  # The actor's current grant and company reach decide a write; the company
  # check then runs as for a read, so a missing company stays `:company_not_found`.
  defp authorize_write(scope, company_id) do
    with {:ok, _actor} <- Authorization.authorize(scope, company_id, @manage_capability) do
      validate_company(scope, company_id)
    else
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp validate_company(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
    end
  end

  defp public_result({:ok, record}, view), do: {:ok, view.(record)}
  defp public_result(error, _view), do: error

  defp entry_view(entry), do: Map.take(entry, [:id, :kind, :code, :label, :active])
  defp alias_view(alias_record), do: Map.take(alias_record, [:id, :entry_id, :label])
  defp exception_view(exception), do: Map.take(exception, [:id, :on_date, :label])
end
