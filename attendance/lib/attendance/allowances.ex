defmodule Bilimbi.People.Attendance.Allowances do
  @moduledoc false
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Attendance.{Access, AllowanceRule}

  def list(scope, company_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      {:ok,
       Repo.all(
         from(r in Tenancy.scope_query(AllowanceRule, scope),
           where: r.company_id == ^company_id,
           order_by: [asc: r.code, desc: r.effective_from, asc: r.id]
         )
       )}
    end
  end

  def create(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, company} <- Access.current_company(scope, company_id) do
      values =
        Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
        |> Map.put("tenant_id", Scope.tenant_id(scope))
        |> Map.put("company_id", company.platform_company_id)

      changeset =
        AllowanceRule.changeset(%AllowanceRule{}, values)

      if changeset.valid? do
        Repo.transaction(fn ->
          code = Ecto.Changeset.get_field(changeset, :code)

          lock_key = :erlang.phash2({company.platform_company_id, code})
          Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [lock_key])

          if overlaps?(scope, company.platform_company_id, changeset) do
            Repo.rollback(:effective_period_overlap)
          end

          case Repo.insert(changeset) do
            {:ok, rule} -> rule
            {:error, error} -> Repo.rollback(error)
          end
        end)
      else
        {:error, changeset}
      end
    end
  end

  def create(%Scope{}, _, _), do: {:error, :invalid_rule}

  def set_status(%Scope{} = scope, company_id, rule_id, status)
      when is_integer(rule_id) and status in ["active", "retired"] do
    with {:ok, _company} <- Access.current_company(scope, company_id),
         %AllowanceRule{} = rule <- get_rule(scope, company_id, rule_id),
         {:ok, saved} <- rule |> AllowanceRule.status_changeset(status) |> Repo.update() do
      {:ok, saved}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def set_status(%Scope{}, _, _, _), do: {:error, :invalid_rule}

  def get(%Scope{} = scope, company_id, rule_id) when is_integer(rule_id) do
    with {:ok, _company} <- Access.current_company(scope, company_id),
         %AllowanceRule{} = rule <- get_rule(scope, company_id, rule_id) do
      {:ok, source(rule)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def get(%Scope{}, _, _), do: {:error, :invalid_rule}

  @doc "Returns active rules effective on `as_of` as stable Payroll source values."
  def sources(%Scope{} = scope, company_id, %Date{} = as_of) do
    with {:ok, _company} <- Access.current_company(scope, company_id) do
      rows =
        Repo.all(
          from(r in Tenancy.scope_query(AllowanceRule, scope),
            where:
              r.company_id == ^company_id and r.status == "active" and
                r.effective_from <= ^as_of and
                (is_nil(r.effective_until) or r.effective_until >= ^as_of),
            order_by: [asc: r.code]
          )
        )

      {:ok, Enum.map(rows, &source/1)}
    end
  end

  def sources(%Scope{}, _, _), do: {:error, :invalid_date}

  defp overlaps?(scope, company_id, changeset) do
    code = Ecto.Changeset.get_field(changeset, :code)
    from_date = Ecto.Changeset.get_field(changeset, :effective_from)
    until_date = Ecto.Changeset.get_field(changeset, :effective_until)

    query =
      from(r in Tenancy.scope_query(AllowanceRule, scope),
        where:
          r.company_id == ^company_id and r.code == ^code and
            (is_nil(r.effective_until) or r.effective_until >= ^from_date)
      )

    query = if until_date, do: where(query, [r], r.effective_from <= ^until_date), else: query
    Repo.exists?(query)
  end

  defp get_rule(scope, company_id, rule_id) do
    Repo.one(
      from(r in Tenancy.scope_query(AllowanceRule, scope),
        where: r.company_id == ^company_id and r.id == ^rule_id
      )
    )
  end

  defp source(rule),
    do:
      Map.take(rule, [
        :id,
        :code,
        :name,
        :unit,
        :value,
        :currency,
        :effective_from,
        :effective_until,
        :status
      ])
end
