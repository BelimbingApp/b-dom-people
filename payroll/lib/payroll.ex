defmodule Bilimbi.People.Payroll do
  @moduledoc """
  Company-scoped payroll foundation. Definitions and mappings are append-only,
  effective-dated versions. Runs freeze their setup; locking is irreversible.
  Calculation replays accepted contributions against frozen rates; independent
  decisions release private Base Artifacts documents.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Authz, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Core.{Company, Employee}
  alias Bilimbi.People.{Attendance, Claims, Leave, Workforce}
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Payroll.{
    Contribution,
    Calculation,
    Decision,
    Document,
    Replay,
    DocumentOwner,
    ResultLine
  }

  alias Bilimbi.Base.Artifacts

  alias Bilimbi.People.Payroll.{
    AttendanceAllowanceMapping,
    Classification,
    Item,
    Mapping,
    Period,
    Run
  }

  @view "people.payroll.view"
  @manage "people.payroll.manage"
  @attendance "people.payroll.attendance-mappings.manage"
  @lookup_limit 1_000

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
    do: create_version(scope, company_id, Classification, attrs, @manage, fn _ -> :ok end)

  def create_item(%Scope{} = scope, company_id, attrs) do
    create_version(scope, company_id, Item, attrs, @manage, fn item ->
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
    create_version(scope, company_id, Mapping, attrs, @manage, fn mapping ->
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

  @doc "Active allowance rule versions not ended by `as_of`, company pay items and attendance mapping versions."
  def attendance_allowances(%Scope{} = scope, company_id, as_of \\ Date.utc_today()) do
    with {:ok, _} <- authorize(scope, company_id, @attendance),
         {:ok, rules} <- Attendance.list_allowance_rules(scope, company_id) do
      {:ok,
       %{
         sources:
           rules
           |> active_rules(as_of, nil)
           |> Enum.sort_by(&{&1.code, Date.to_gregorian_days(&1.effective_from)}),
         items: rows(Item, scope, company_id),
         mappings: rows(AttendanceAllowanceMapping, scope, company_id)
       }}
    end
  end

  def create_attendance_allowance_mapping(%Scope{} = scope, company_id, attrs) do
    create_version(scope, company_id, AttendanceAllowanceMapping, attrs, @attendance, fn
      mapping ->
        with {:ok, rules} <- Attendance.list_allowance_rules(scope, company_id),
             %Item{} = item <- fetch(Item, scope, company_id, mapping.item_id),
             true <- covers?(item, mapping),
             versions =
               rules
               |> Enum.filter(&(&1.code == mapping.attendance_rule_code))
               |> active_rules(mapping.effective_from, mapping.effective_to),
             true <- versions != [] and Enum.all?(versions, &(&1.currency == item.currency)) do
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
             {:ok, rules} <- Attendance.list_allowance_rules(scope, company_id),
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

          period_rules = active_rules(rules, period.starts_on, period.ends_on)

          {attendance_mappings, mismatched} =
            effective_rows(AttendanceAllowanceMapping, scope, company_id, period)
            |> Enum.filter(&(&1.item_id in item_ids))
            |> Enum.split_with(fn mapping ->
              period_rules
              |> Enum.filter(&(&1.code == mapping.attendance_rule_code))
              |> active_rules(mapping.effective_from, mapping.effective_to)
              |> Enum.all?(&(&1.currency == currency))
            end)

          mismatched_codes = mismatched |> Enum.map(& &1.attendance_rule_code) |> Enum.uniq()

          mapped =
            MapSet.new(mappings, &{&1.source_kind, &1.source_key})
            |> MapSet.union(
              MapSet.new(
                Enum.map(attendance_mappings, & &1.attendance_rule_code) ++ mismatched_codes,
                &{"attendance", &1}
              )
            )

          currency_mismatches =
            for code <- Enum.sort(mismatched_codes) do
              rule = Enum.find(period_rules, &(&1.code == code and &1.currency != currency))

              %{
                "source_kind" => "attendance",
                "source_key" => code,
                "name" => rule.name,
                "reason" => "currency mismatch"
              }
            end

          sources =
            Map.put(
              sources,
              "attendance",
              period_rules
              |> Enum.filter(&(&1.currency == currency))
              |> Enum.sort_by(& &1.code)
              |> Enum.uniq_by(& &1.code)
              |> Enum.map(&%{key: &1.code, name: &1.name, active: true})
            )

          snapshot = %{
            "period" => json(period),
            "items" => Enum.map(items, &json/1),
            "classifications" =>
              effective_rows(Classification, scope, company_id, period) |> Enum.map(&json/1),
            "mappings" => Enum.map(mappings, &json/1),
            "attendance_mappings" => Enum.map(attendance_mappings, &json/1),
            "unmapped_sources" =>
              for {kind, choices} <- Enum.sort(sources),
                  choice <- choices,
                  choice.active or MapSet.member?(requested, {kind, choice.key}),
                  not MapSet.member?(mapped, {kind, choice.key}) do
                %{"source_kind" => kind, "source_key" => choice.key, "name" => choice.name}
              end ++ currency_mismatches
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

  defp active_rules(rules, from_date, to_date) do
    Enum.filter(rules, fn rule ->
      rule.status == "active" and
        (is_nil(to_date) or Date.compare(rule.effective_from, to_date) != :gt) and
        (is_nil(rule.effective_until) or Date.compare(rule.effective_until, from_date) != :lt)
    end)
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

  @doc "Accepts an operator-attested contribution with a company-unique replay key."
  def intake(%Scope{} = scope, company_id, run_id, attrs) do
    with {:ok, _} <- authorize(scope, company_id, @manage) do
      transaction(scope, company_id, fn ->
        changeset =
          Contribution.changeset(
            %Contribution{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              run_id: run_id,
              created_by_actor_id: Scope.actor(scope).user_id
            },
            attrs
          )

        with {:ok, input} <- Ecto.Changeset.apply_action(changeset, :insert),
             %Run{} = run <- fetch(Run, scope, company_id, run_id),
             nil <- fetch_for_run(Calculation, scope, company_id, run_id),
             {:ok, %ReadResult{freshness: :current, value: _}} <-
               Workforce.employee(scope, company_id, input.employee_id),
             true <- valid_input?(run, input) do
          case Repo.one(
                 from(c in scoped(Contribution, scope, company_id),
                   where: c.source_key == ^input.source_key
                 )
               ) do
            nil ->
              insert(changeset)

            previous ->
              keys = [
                :run_id,
                :employee_id,
                :item_id,
                :source_key,
                :evidence,
                :on_date,
                :direction
              ]

              if Map.take(previous, keys) == Map.take(input, keys) and
                   Decimal.equal?(previous.units, input.units),
                 do: {:ok, public(previous)},
                 else: {:error, :replay_conflict}
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :intake_unavailable}
        end
      end)
    end
  end

  @doc "Intakes an attested mapped source using its frozen mapping and exact units."
  def intake_mapped(%Scope{} = scope, company_id, run_id, source_kind, source_key, attrs) do
    with {:ok, _} <- authorize(scope, company_id, @manage),
         %Run{} = run <- fetch(Run, scope, company_id, run_id),
         {:ok, on_date} <-
           Ecto.Type.cast(:date, Map.get(attrs, :on_date, Map.get(attrs, "on_date"))) do
      date = Date.to_iso8601(on_date)

      mappings =
        Enum.filter(run.snapshot["mappings"], fn mapping ->
          mapping["source_kind"] == source_kind and mapping["source_key"] == source_key and
            mapping["effective_from"] <= date and
            (is_nil(mapping["effective_to"]) or mapping["effective_to"] >= date)
        end)

      case mappings do
        [mapping] ->
          intake(
            scope,
            company_id,
            run_id,
            attrs
            |> Map.new(fn {key, value} -> {to_string(key), value} end)
            |> Map.put("item_id", mapping["item_id"])
          )

        _ ->
          {:error, :source_not_mapped}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :source_not_mapped}
    end
  end

  @doc "Intakes operator-attested allowance units through the frozen Attendance mapping."
  def intake_attendance_allowance(%Scope{} = scope, company_id, run_id, attrs) do
    with {:ok, _} <- authorize(scope, company_id, @manage),
         %Run{} = run <- fetch(Run, scope, company_id, run_id),
         {:ok, on_date} <-
           Ecto.Type.cast(:date, Map.get(attrs, :on_date, Map.get(attrs, "on_date"))) do
      date = Date.to_iso8601(on_date)
      code = Map.get(attrs, :attendance_rule_code, Map.get(attrs, "attendance_rule_code"))

      mappings =
        Enum.filter(Map.get(run.snapshot, "attendance_mappings", []), fn mapping ->
          mapping["attendance_rule_code"] == code and mapping["effective_from"] <= date and
            (is_nil(mapping["effective_to"]) or mapping["effective_to"] >= date)
        end)

      case mappings do
        [mapping] ->
          intake(
            scope,
            company_id,
            run_id,
            attrs
            |> Map.new(fn {key, value} -> {to_string(key), value} end)
            |> Map.put("item_id", mapping["item_id"])
            |> Map.put("direction", "earning")
          )

        _ ->
          {:error, :allowance_not_mapped}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :allowance_not_mapped}
    end
  end

  defp valid_input?(run, input) do
    period = run.snapshot["period"]
    date = Date.to_iso8601(input.on_date)
    items = Enum.filter(run.snapshot["items"], &(&1["id"] == input.item_id))

    case items do
      [item] ->
        date >= period["starts_on"] and date <= period["ends_on"] and
          date >= item["effective_from"] and
          (is_nil(item["effective_to"]) or date <= item["effective_to"])

      _ ->
        false
    end
  end

  @doc "Calculates once after setup locking; replay returns the same immutable record."
  def calculate(%Scope{} = scope, company_id, run_id) do
    with {:ok, _} <- authorize(scope, company_id, @manage) do
      transaction(scope, company_id, fn ->
        with %Run{locked_at: locked} = run when not is_nil(locked) <-
               fetch(Run, scope, company_id, run_id) do
          case fetch_for_run(Calculation, scope, company_id, run_id) do
            nil ->
              inputs =
                Repo.all(
                  from(c in scoped(Contribution, scope, company_id),
                    where: c.run_id == ^run_id,
                    order_by: c.source_key
                  )
                )

              if inputs == [], do: Repo.rollback(:no_contributions)
              ids = inputs |> Enum.map(& &1.employee_id) |> Enum.uniq()

              if company_employees?(scope, company_id, ids) do
                snapshot = %{
                  "setup" => run.snapshot,
                  "contributions" => Enum.map(inputs, &json/1),
                  "result" => Replay.calculate(run.snapshot, Enum.map(inputs, &json/1))
                }

                digest =
                  :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))
                  |> Base.encode16(case: :lower)

                for line <- snapshot["result"]["lines"] do
                  Repo.insert!(%ResultLine{
                    tenant_id: Scope.tenant_id(scope),
                    company_id: company_id,
                    created_by_actor_id: Scope.actor(scope).user_id,
                    run_id: run_id,
                    contribution_id: line["id"],
                    employee_id: line["employee_id"],
                    direction: line["direction"],
                    amount: Decimal.new(line["amount"])
                  })
                end

                %Calculation{
                  tenant_id: Scope.tenant_id(scope),
                  company_id: company_id,
                  run_id: run_id,
                  created_by_actor_id: Scope.actor(scope).user_id,
                  snapshot: snapshot,
                  digest: digest
                }
                |> Repo.insert()
                |> result()
              else
                {:error, :employee_not_found}
              end

            row ->
              {:ok, public(row)}
          end
        else
          _ -> {:error, :run_not_locked}
        end
      end)
    end
  end

  defp company_employees?(scope, company_id, ids) do
    ids
    |> Enum.chunk_every(@lookup_limit)
    |> Enum.all?(fn page ->
      {:ok, employees} = Employee.get_tenant_employees(scope, page)
      Enum.all?(page, &match?(%{company_id: ^company_id}, Map.get(employees, &1)))
    end)
  end

  def run_output(%Scope{} = scope, company_id, run_id) do
    with {:ok, _} <- authorize(scope, company_id, @view),
         %Run{} = run <- fetch(Run, scope, company_id, run_id) do
      {:ok,
       %{
         run: public(run),
         contributions:
           Repo.all(
             from(c in scoped(Contribution, scope, company_id),
               where: c.run_id == ^run_id,
               order_by: c.source_key
             )
           )
           |> Enum.map(&public/1),
         calculation: maybe_public(fetch_for_run(Calculation, scope, company_id, run_id)),
         decision: maybe_public(fetch_for_run(Decision, scope, company_id, run_id)),
         documents:
           Repo.all(
             from(d in scoped(Document, scope, company_id),
               where: d.run_id == ^run_id,
               order_by: d.id
             )
           )
           |> Enum.map(&public/1)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Independent final approval or rejection; neither decision can be overwritten."
  def decide_run(%Scope{} = scope, company_id, run_id, outcome, reason) do
    with {:ok, _} <- authorize(scope, company_id, "people.payroll.approve"),
         true <-
           outcome in ["approved", "rejected"] and is_binary(reason) and
             String.length(String.trim(reason)) in 1..500 do
      transaction(scope, company_id, fn ->
        actor = Scope.actor(scope).user_id

        with %Run{} = run <- fetch(Run, scope, company_id, run_id),
             %Calculation{} = calculation <- fetch_for_run(Calculation, scope, company_id, run_id),
             nil <- fetch_for_run(Decision, scope, company_id, run_id),
             false <-
               actor in [
                 run.created_by_actor_id,
                 run.locked_by_actor_id,
                 calculation.created_by_actor_id
               ],
             false <-
               Repo.exists?(
                 from(c in scoped(Contribution, scope, company_id),
                   where: c.run_id == ^run_id and c.created_by_actor_id == ^actor
                 )
               ) do
          %Decision{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            run_id: run_id,
            created_by_actor_id: actor,
            outcome: outcome,
            reason: String.trim(reason)
          }
          |> Repo.insert()
          |> result()
        else
          _ -> {:error, :not_decidable}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_decision}
    end
  end

  @doc "Generates an approved report or payslip through Base's private PDF service."
  def generate_document(%Scope{} = scope, company_id, run_id, kind, employee_id \\ nil) do
    reference = %{subject: to_string(run_id), kind: kind}

    with :ok <- document_access(scope, company_id, :create, reference),
         {:ok, data} <- document_data(scope, company_id, reference, employee_id),
         {:ok, artifact} <-
           Artifacts.generate_pdf(scope, company_id, DocumentOwner, reference, data) do
      transaction(scope, company_id, fn ->
        %Document{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          run_id: run_id,
          created_by_actor_id: Scope.actor(scope).user_id,
          employee_id: employee_id,
          artifact_id: artifact.id,
          kind: kind
        }
        |> Repo.insert()
        |> result()
      end)
    end
  end

  def read_document(%Scope{} = scope, company_id, artifact_id),
    do: Artifacts.read(scope, company_id, DocumentOwner, artifact_id)

  @doc false
  def document_access(scope, company_id, operation, reference) do
    capability = if operation == :read, do: @view, else: @manage

    with {:ok, _} <- authorize(scope, company_id, capability) do
      if operation == :purge do
        :ok
      else
        with %{subject: subject, kind: kind}
             when is_binary(subject) and kind in ["report", "payslip"] <- reference,
             {id, ""} <- Integer.parse(subject),
             %Decision{outcome: "approved"} <- fetch_for_run(Decision, scope, company_id, id) do
          :ok
        else
          _ -> {:error, :not_found}
        end
      end
    end
  end

  @doc false
  def document_data(scope, company_id, reference, employee_id) do
    with :ok <- document_access(scope, company_id, :read, reference),
         {run_id, ""} <- Integer.parse(reference.subject),
         {:ok, %{run: run, calculation: calculation}} <- run_output(scope, company_id, run_id),
         true <-
           (reference.kind == "report" and is_nil(employee_id)) or
             (reference.kind == "payslip" and is_integer(employee_id) and
                Enum.any?(
                  calculation.snapshot["result"]["totals"],
                  &(&1["employee_id"] == employee_id)
                )) do
      rows =
        calculation.snapshot["result"]["lines"]
        |> Enum.filter(&(is_nil(employee_id) or &1["employee_id"] == employee_id))

      totals =
        calculation.snapshot["result"]["totals"]
        |> Enum.filter(&(is_nil(employee_id) or &1["employee_id"] == employee_id))

      {:ok,
       %{
         employee_id: employee_id,
         currency: run.currency,
         digest: calculation.digest,
         lines: rows,
         totals: totals
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_document}
    end
  end

  defp fetch_for_run(schema, scope, company_id, run_id),
    do: Repo.one(from(r in scoped(schema, scope, company_id), where: r.run_id == ^run_id))

  defp maybe_public(nil), do: nil
  defp maybe_public(row), do: public(row)

  defp create_version(%Scope{} = scope, company_id, schema, attrs, capability, validate) do
    with {:ok, _} <- authorize(scope, company_id, capability) do
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
          same_currency(query, row)
          |> where([r], r.source_kind == ^row.source_kind and r.source_key == ^row.source_key)

        %AttendanceAllowanceMapping{} ->
          same_currency(query, row)
          |> where([r], r.attendance_rule_code == ^row.attendance_rule_code)

        _ ->
          where(query, [r], r.code == ^row.code)
      end

    if Repo.exists?(query), do: {:error, :overlapping_version}, else: :ok
  end

  defp same_currency(query, row),
    do:
      from(r in query,
        join: i in Item,
        on: i.id == r.item_id,
        join: n in Item,
        on: n.id == ^row.item_id and n.currency == i.currency
      )

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
