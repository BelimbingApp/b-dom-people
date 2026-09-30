defmodule Bilimbi.People.Payroll do
  @moduledoc """
  Company-scoped payroll foundation. Definitions and mappings are append-only,
  effective-dated versions. Runs freeze their setup; locking is irreversible.
  Calculation, contributions and financial outputs belong to the next slice.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Authz, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Core.Company
  alias Bilimbi.People.{Claims, Leave}
  alias Bilimbi.People.Payroll.{Classification, Item, Mapping, Period, Run}

  @view "people.payroll.view"
  @manage "people.payroll.manage"

  def allowed?(%Scope{} = scope, company_id, capability) do
    match?({:ok, _}, authorize(scope, company_id, capability))
  end

  def setup(%Scope{} = scope, company_id) do
    with {:ok, company} <- authorize(scope, company_id, @view) do
      {:ok,
       %{
         country: Settings.get("people.payroll.country", setting_scope(company)),
         currencies: Settings.get("people.payroll.currencies", setting_scope(company)),
         classifications: rows(Classification, scope, company_id),
         items: rows(Item, scope, company_id),
         periods: rows(Period, scope, company_id),
         mappings: rows(Mapping, scope, company_id),
         runs: rows(Run, scope, company_id)
       }}
    end
  end

  def put_settings(%Scope{} = scope, company_id, country, currencies) do
    with {:ok, company} <- authorize(scope, company_id, @manage),
         true <- is_binary(country) and String.length(String.trim(country)) in 1..100,
         true <- is_list(currencies) and length(currencies) <= 20,
         true <- Enum.all?(currencies, &(is_binary(&1) and &1 =~ ~r/^[A-Z]{3}$/)) do
      transaction(scope, company_id, fn ->
        with {:ok, _} <-
               Settings.put(
                 "people.payroll.country",
                 String.trim(country),
                 setting_scope(company)
               ),
             {:ok, _} <-
               Settings.put(
                 "people.payroll.currencies",
                 Enum.uniq(currencies),
                 setting_scope(company)
               ),
             do: {:ok, :saved}
      end)
    else
      false -> {:error, :invalid_settings}
      error -> error
    end
  end

  def create_classification(%Scope{} = scope, company_id, attrs),
    do: create_version(scope, company_id, Classification, attrs, fn _ -> :ok end)

  def create_item(%Scope{} = scope, company_id, attrs) do
    create_version(scope, company_id, Item, attrs, fn item ->
      with {:ok, company} <- Company.get_company(scope, company_id),
           true <-
             item.currency in Settings.get("people.payroll.currencies", setting_scope(company)),
           %Classification{} = classification <-
             fetch(Classification, scope, company_id, item.classification_id),
           true <- covers?(classification, item),
           true <- Decimal.equal?(item.amount, Decimal.round(item.amount, 6)) do
        :ok
      else
        _ -> {:error, :invalid_item}
      end
    end)
  end

  def create_period(%Scope{} = scope, company_id, attrs) do
    with {:ok, _} <- authorize(scope, company_id, @manage) do
      transaction(scope, company_id, fn ->
        changeset =
          Period.changeset(
            %Period{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              created_by_actor_id: Scope.actor(scope).user_id
            },
            attrs
          )

        with {:ok, period} <- Ecto.Changeset.apply_action(changeset, :insert),
             true <- Date.compare(period.pay_on, period.ends_on) != :lt,
             false <-
               Repo.exists?(
                 from(p in scoped(Period, scope, company_id),
                   where: p.starts_on <= ^period.ends_on and p.ends_on >= ^period.starts_on
                 )
               ),
             do: insert(changeset)
      end)
    end
  end

  @doc "Lists mapping choices through each owning module's public API."
  def sources(%Scope{} = scope, company_id) do
    with {:ok, _} <- authorize(scope, company_id, @view),
         {:ok, leave} <- Leave.list_types(scope, company_id),
         {:ok, claims} <- Claims.claim_types(scope, company_id) do
      {:ok,
       %{
         "attendance" => [],
         "leave" =>
           Enum.map(
             leave,
             &%{key: to_string(&1.id), name: &1.name, active: &1.status == "active"}
           ),
         "claims" => Enum.map(claims, &%{key: to_string(&1.id), name: &1.name, active: &1.active})
       }}
    end
  end

  def create_mapping(%Scope{} = scope, company_id, attrs) do
    create_version(scope, company_id, Mapping, attrs, fn mapping ->
      with {:ok, sources} <- sources(scope, company_id),
           true <-
             Enum.any?(Map.get(sources, mapping.source_kind, []), &(&1.key == mapping.source_key)),
           %Item{} = item <- fetch(Item, scope, company_id, mapping.item_id),
           true <- covers?(item, mapping) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_mapping}
      end
    end)
  end

  @doc "Freezes all setup effective for the period, including decimal strings."
  def create_run(%Scope{} = scope, company_id, period_id, currency) do
    with {:ok, company} <- authorize(scope, company_id, @manage) do
      transaction(scope, company_id, fn ->
        country = Settings.get("people.payroll.country", setting_scope(company))

        with %Period{} = period <- fetch(Period, scope, company_id, period_id),
             {:ok, sources} <- sources(scope, company_id),
             {:ok, requested} <- requested_sources(scope, company_id, period),
             true <- is_binary(country) and String.trim(country) != "",
             true <- currency in Settings.get("people.payroll.currencies", setting_scope(company)),
             false <-
               Repo.exists?(
                 from(r in scoped(Run, scope, company_id),
                   where: r.period_id == ^period_id and r.currency == ^currency
                 )
               ) do
          items =
            effective_rows(Item, scope, company_id, period)
            |> Enum.filter(&(&1.currency == currency))

          item_ids = Enum.map(items, & &1.id)

          mappings =
            effective_rows(Mapping, scope, company_id, period)
            |> Enum.filter(&(&1.item_id in item_ids))

          mapped = MapSet.new(mappings, &{&1.source_kind, &1.source_key})

          snapshot = %{
            "period" => json(period),
            "items" => Enum.map(items, &json/1),
            "classifications" =>
              effective_rows(Classification, scope, company_id, period) |> Enum.map(&json/1),
            "mappings" => Enum.map(mappings, &json/1),
            "unmapped_sources" =>
              for {kind, choices} <- Enum.sort(sources),
                  choice <- choices,
                  choice.active or MapSet.member?(requested, {kind, choice.key}),
                  not MapSet.member?(mapped, {kind, choice.key}) do
                %{"source_kind" => kind, "source_key" => choice.key, "name" => choice.name}
              end
          }

          %Run{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            created_by_actor_id: Scope.actor(scope).user_id
          }
          |> Run.changeset(%{
            period_id: period_id,
            country: country,
            currency: currency,
            snapshot: snapshot
          })
          |> insert()
        else
          {:error, _} = error -> error
          _ -> {:error, :run_unavailable}
        end
      end)
    end
  end

  defp requested_sources(scope, company_id, period) do
    with {:ok, leave} <-
           Leave.requested_type_ids(scope, company_id, period.starts_on, period.ends_on),
         {:ok, claims} <-
           Claims.requested_claim_type_ids(scope, company_id, period.starts_on, period.ends_on) do
      {:ok,
       MapSet.new(
         Enum.map(leave, &{"leave", to_string(&1)}) ++
           Enum.map(claims, &{"claims", to_string(&1)})
       )}
    end
  end

  def lock_run(%Scope{} = scope, company_id, run_id) do
    with {:ok, _} <- authorize(scope, company_id, @manage),
         %{type: :user, user_id: actor_id, impersonator_id: nil} <- Scope.actor(scope) do
      transaction(scope, company_id, fn ->
        case fetch(Run, scope, company_id, run_id) do
          %Run{locked_at: nil} = run ->
            run
            |> Ecto.Changeset.change(
              locked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
              locked_by_actor_id: actor_id
            )
            |> Repo.update()
            |> result()

          %Run{} ->
            {:error, :locked}

          _ ->
            {:error, :not_found}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp create_version(%Scope{} = scope, company_id, schema, attrs, validate) do
    with {:ok, _} <- authorize(scope, company_id, @manage) do
      transaction(scope, company_id, fn ->
        changeset =
          schema.changeset(
            struct(schema,
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              created_by_actor_id: Scope.actor(scope).user_id
            ),
            attrs
          )

        with {:ok, row} <- Ecto.Changeset.apply_action(changeset, :insert),
             :ok <- validate.(row),
             :ok <- no_overlap(schema, scope, company_id, row),
             do: insert(changeset)
      end)
    end
  end

  defp no_overlap(schema, scope, company_id, row) do
    query =
      scoped(schema, scope, company_id)
      |> where([r], is_nil(r.effective_to) or r.effective_to >= ^row.effective_from)

    query =
      if row.effective_to,
        do: where(query, [r], r.effective_from <= ^row.effective_to),
        else: query

    query =
      case row do
        %Mapping{} ->
          from(r in query,
            join: i in Item,
            on: i.id == r.item_id,
            join: n in Item,
            on: n.id == ^row.item_id and n.currency == i.currency,
            where: r.source_kind == ^row.source_kind and r.source_key == ^row.source_key
          )

        _ ->
          where(query, [r], r.code == ^row.code)
      end

    if Repo.exists?(query), do: {:error, :overlapping_version}, else: :ok
  end

  defp covers?(parent, child),
    do:
      Date.compare(parent.effective_from, child.effective_from) != :gt and
        (is_nil(parent.effective_to) or
           (not is_nil(child.effective_to) and
              Date.compare(parent.effective_to, child.effective_to) != :lt))

  defp effective_rows(schema, scope, company_id, period) do
    scoped(schema, scope, company_id)
    |> where(
      [r],
      r.effective_from <= ^period.ends_on and
        (is_nil(r.effective_to) or r.effective_to >= ^period.starts_on)
    )
    |> order_by([r], asc: r.id)
    |> Repo.all()
  end

  defp authorize(scope, company_id, capability) do
    with %{type: :user, impersonator_id: nil} <- Scope.actor(scope),
         {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, company} <- Company.authorize_company_target(actor, company_id, capability),
         true <- company.status == "active" do
      {:ok, company}
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp setting_scope(company), do: SettingsScope.company(company.id, company.tenant_id)

  defp scoped(schema, scope, company_id),
    do: from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company_id)

  defp fetch(schema, scope, company_id, id) when is_integer(id),
    do: scoped(schema, scope, company_id) |> where([r], r.id == ^id) |> Repo.one()

  defp fetch(_, _, _, _), do: nil

  defp rows(schema, scope, id),
    do: scoped(schema, scope, id) |> order_by([r], asc: r.id) |> Repo.all() |> Enum.map(&public/1)

  defp public(row), do: row |> Map.from_struct() |> Map.drop([:__meta__, :tenant_id, :company_id])
  defp result({:ok, row}), do: {:ok, public(row)}
  defp result(error), do: error
  defp insert(changeset), do: changeset |> Repo.insert() |> result()

  defp transaction(scope, company_id, fun) do
    Repo.transaction(fn ->
      # A private advisory lock needs no sibling table read and serializes all
      # foundation writes and snapshots for this tenant/company.
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "people/payroll:#{Scope.tenant_id(scope)}:#{company_id}"
      ])

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_record)
      end
    end)
  end

  defp json(row),
    do: Map.new(public(row), fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value
end
