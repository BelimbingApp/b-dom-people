defmodule Bilimbi.People.Progression do
  @moduledoc """
  Company-owned immutable progression policy versions and explanatory eligibility.
  Publication does not decide promotion, position, remuneration or employee status.
  Evidence is read through Skills and Performance public APIs for the linked employee.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias Bilimbi.Base.{Authz, Repo, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.Audit.Context
  alias Bilimbi.Core.{Company, User}
  alias Bilimbi.People.{Skills, Performance, Workforce}
  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Progression.Policy

  def allowed?(%Scope{} = scope, company_id, capability) do
    with {:ok, _actor} <- Authz.scope_actor(scope),
         %{allowed: true} <- Authz.can(scope, capability),
         {:ok, _} <- Authorization.authorize_company(scope, company_id, capability),
         do: true,
         else: (_ -> false)
  end

  def allowed?(_, _, _), do: false

  @doc "Bounded policy history; page and page size are validated."
  def policies(%Scope{} = scope, company_id, opts \\ []) do
    with {:ok, _} <- authorize(scope, company_id, "people.progression.policy.view") do
      page = Keyword.get(opts, :page, 1)
      size = Keyword.get(opts, :page_size, 25)

      if is_integer(page) and page > 0 and size in [10, 25, 50, 100] do
        query = scoped(scope, company_id)
        total = Repo.aggregate(query, :count)
        page = min(page, max(1, ceil(total / size)))

        rows =
          query
          |> order_by([p], desc: p.effective_from, desc: p.id)
          |> limit(^size)
          |> offset(^((page - 1) * size))
          |> Repo.all()
          |> Enum.map(&view/1)

        {:ok, %{rows: rows, total: total, page: page, page_size: size}}
      else
        {:error, :invalid_options}
      end
    end
  end

  @doc "A new immutable draft. Business thresholds and periods are governed data."
  def draft(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, fn actor ->
      row = %Policy{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        actor_user_id: actor.id,
        status: "draft"
      }

      cs =
        row
        |> cast(attrs, [:code, :version, :name, :effective_from, :rules])
        |> validate_required([:code, :version, :name, :effective_from, :rules])
        |> validate_number(:version, greater_than: 0)
        |> validate_length(:code, max: 100)
        |> validate_length(:name, max: 200)

      cs =
        Enum.reduce([:code, :name], cs, fn key, cs ->
          if is_binary(get_field(cs, key)),
            do: put_change(cs, key, String.trim(get_field(cs, key))),
            else: cs
        end)

      row = unwrap!(apply_action(cs, :insert))
      require!(row.code != "" and row.name != "", :invalid_policy)
      validate_rules!(scope, company_id, row.rules)
      cs |> Repo.insert() |> unwrap!() |> view()
    end)
  end

  @doc "Publish once, serialized by the live company lock; past publications remain intact."
  def publish(%Scope{} = scope, company_id, id) do
    write(scope, company_id, fn actor ->
      row =
        if is_integer(id),
          do: scoped(scope, company_id) |> where([p], p.id == ^id) |> Repo.one(),
          else: nil

      require!(row != nil, :not_found)
      require!(row.status == "draft", :already_published)
      validate_rules!(scope, company_id, row.rules)

      require!(
        !Repo.exists?(
          from(p in scoped(scope, company_id),
            where: p.status == "published" and p.code == ^row.code and p.version >= ^row.version
          )
        ),
        :version_order
      )

      require!(
        !Repo.exists?(
          from(p in scoped(scope, company_id),
            where:
              p.status == "published" and p.code == ^row.code and
                p.effective_from > ^row.effective_from
          )
        ),
        :effective_order
      )

      row
      |> change(
        status: "published",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second),
        published_by_user_id: actor.id
      )
      |> Repo.update()
      |> unwrap!()
      |> view()
    end)
  end

  @doc "Explain each policy code's currently effective version for this actor's own working employee."
  def explain(%Scope{} = scope, company_id) do
    with {:ok, actor} <- authorize(scope, company_id, "people.progression.self.view"),
         {:ok, user} <- User.get_user(scope, company_id, actor.id),
         id when is_integer(id) <- user.employee_id,
         {:ok, read} <- Workforce.employee(scope, company_id, id),
         {:ok, _} <- ReadResult.require_current(read) do
      today = Date.utc_today()

      policies =
        scoped(scope, company_id)
        |> where([p], p.status == "published" and p.effective_from <= ^today)
        |> distinct([p], p.code)
        |> order_by([p], asc: p.code, desc: p.effective_from, desc: p.version)
        |> Repo.all()

      if policies == [] do
        {:error, :no_published_policy}
      else
        Enum.reduce_while(policies, {:ok, []}, fn policy, {:ok, acc} ->
          case explain_policy(scope, actor, company_id, policy) do
            {:ok, explanation} -> {:cont, {:ok, acc ++ [explanation]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, explanations} -> {:ok, %{employee_id: id, explanations: explanations}}
          error -> error
        end
      end
    else
      nil -> {:error, :employee_unavailable}
      error -> error
    end
  end

  defp explain_policy(scope, actor, company_id, policy) do
    with {:ok, competence} <- competence(actor, company_id, policy.rules["competence"]),
         {:ok, performance} <- performance(scope, company_id, policy.rules["performance"]) do
      rules = competence ++ performance

      status =
        cond do
          Enum.any?(rules, &(&1.status == :not_met)) -> :not_met
          Enum.any?(rules, &(&1.status == :unknown)) -> :unknown
          true -> :met
        end

      {:ok, %{policy: view(policy), rules: rules, status: status}}
    end
  end

  defp competence(_actor, _company_id, []), do: {:ok, []}

  defp competence(actor, company_id, rules) do
    with {:ok, standing} <- Skills.standing(actor, company_id) do
      {:ok,
       Enum.map(rules, fn rule ->
         score = Enum.find(standing.scores, &(&1.skill_id == rule["skill_id"]))

         current =
           score && score.state == :current && score.assessment_profile_id == rule["profile_id"] &&
             score.assessment_profile_version == rule["profile_version"]

         status =
           cond do
             !current -> :unknown
             score.current_level >= rule["required_level"] -> :met
             true -> :not_met
           end

         %{
           source: :skill,
           code: rule["code"],
           status: status,
           required_level: rule["required_level"],
           observed_level: if(current, do: score.current_level),
           assessment_id: score && score.assessment_id
         }
       end)}
    end
  end

  defp performance(_scope, _company_id, nil), do: {:ok, []}

  defp performance(scope, company_id, rule) do
    with {:ok, reviews} <- eligible_reviews(scope, company_id, rule, 1, []) do
      latest =
        Enum.max_by(
          reviews,
          &{Date.to_gregorian_days(&1.period_end), &1.version, &1.id},
          fn -> nil end
        )

      status =
        cond do
          latest == nil -> String.to_existing_atom(rule["missing_evidence"])
          latest.outcome in rule["accepted_outcomes"] -> :met
          true -> :not_met
        end

      {:ok,
       [
         %{
           source: :performance,
           code: "performance",
           status: status,
           review_id: latest && latest.id,
           review_version: latest && latest.version,
           supersedes_id: latest && latest.supersedes_id,
           period_start: latest && latest.period_start,
           period_end: latest && latest.period_end
         }
       ]}
    end
  end

  defp eligible_reviews(scope, company_id, rule, page, acc) do
    with {:ok, result} <- Performance.my_records(scope, company_id, page: page, page_size: 100) do
      rows =
        Enum.filter(result.reviews.rows, fn r ->
          Enum.any?(rule["periods"], fn p ->
            Date.compare(r.period_start, Date.from_iso8601!(p["start"])) != :lt and
              Date.compare(r.period_end, Date.from_iso8601!(p["end"])) != :gt
          end)
        end)

      if page * 100 < result.reviews.total,
        do: eligible_reviews(scope, company_id, rule, page + 1, rows ++ acc),
        else: {:ok, rows ++ acc}
    end
  end

  defp validate_rules!(scope, company_id, rules) do
    require!(
      is_map(rules) and Enum.all?(Map.keys(rules), &(&1 in ["competence", "performance"])),
      :invalid_rules
    )

    competence = rules["competence"]
    performance = rules["performance"]

    require!(
      is_list(competence) and length(competence) <= 100 and
        (competence != [] or performance != nil),
      :invalid_rules
    )

    require!(Enum.all?(competence, &is_map/1), :invalid_rules)
    require!(length(Enum.uniq_by(competence, & &1["code"])) == length(competence), :invalid_rules)

    for rule <- competence do
      require!(
        Enum.sort(Map.keys(rule)) == ~w(code profile_id profile_version required_level skill_id),
        :invalid_rules
      )

      require!(
        is_binary(rule["code"]) and String.trim(rule["code"]) != "" and
          byte_size(rule["code"]) <= 100,
        :invalid_rules
      )

      require!(
        is_integer(rule["profile_id"]) and rule["profile_id"] > 0 and
          is_integer(rule["profile_version"]) and rule["profile_version"] > 0 and
          is_integer(rule["skill_id"]) and rule["skill_id"] > 0,
        :invalid_rules
      )

      require!(is_integer(rule["required_level"]) and rule["required_level"] >= 0, :invalid_rules)
      profile = unwrap!(Skills.get_profile(scope, company_id, rule["profile_id"]))

      require!(
        profile.status == "published" and profile.version == rule["profile_version"],
        :profile_unavailable
      )

      require!(
        Enum.any?(
          profile.items,
          &(&1.skill_id == rule["skill_id"] and &1.required_level == rule["required_level"])
        ),
        :profile_unavailable
      )
    end

    if performance do
      require!(
        is_map(performance) and
          Enum.sort(Map.keys(performance)) == ~w(accepted_outcomes missing_evidence periods),
        :invalid_rules
      )

      require!(performance["missing_evidence"] in ["unknown", "not_met"], :invalid_rules)
      outcomes = performance["accepted_outcomes"]

      require!(
        is_list(outcomes) and outcomes != [] and length(outcomes) <= 100 and
          Enum.all?(outcomes, &(is_binary(&1) and String.trim(&1) != "" and byte_size(&1) <= 200)),
        :invalid_rules
      )

      periods = performance["periods"]
      require!(is_list(periods) and periods != [] and length(periods) <= 100, :invalid_rules)

      for p <- periods do
        require!(is_map(p) and Enum.sort(Map.keys(p)) == ~w(end start), :invalid_rules)
        require!(is_binary(p["start"]) and is_binary(p["end"]), :invalid_rules)

        with {:ok, first} <- Date.from_iso8601(p["start"] || ""),
             {:ok, last} <- Date.from_iso8601(p["end"] || "") do
          require!(Date.compare(first, last) != :gt, :invalid_rules)
        else
          _ -> Repo.rollback(:invalid_rules)
        end
      end
    end
  end

  defp authorize(scope, company_id, capability) do
    with true <- allowed?(scope, company_id, capability),
         {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, read} <- Workforce.company(scope, company_id),
         {:ok, _} <- ReadResult.require_current(read),
         do: {:ok, actor},
         else: (
           false -> {:error, :unauthorized}
           error -> error
         )
  end

  defp write(scope, company_id, fun) do
    with {:ok, actor} <- authorize(scope, company_id, "people.progression.policy.manage"),
         nil <- Scope.actor(scope).impersonator_id do
      context = Context.get()

      Context.put(%{
        context
        | actor_type: "user",
          actor_id: actor.id,
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          impersonator_id: nil
      })

      try do
        Repo.transaction(fn ->
          unwrap!(Company.lock_live_company(scope, company_id))
          unwrap!(authorize(scope, company_id, "people.progression.policy.manage"))
          fun.(actor)
        end)
      rescue
        _ in [Ecto.ConstraintError] ->
          {:error, :invariant_refused}

        e in Postgrex.Error ->
          if e.postgres.code in [:unique_violation, :check_violation, :foreign_key_violation],
            do: {:error, :invariant_refused},
            else: reraise(e, __STACKTRACE__)
      after
        Context.put(context)
      end
    else
      id when is_integer(id) -> {:error, :impersonation_refused}
      error -> error
    end
  end

  defp scoped(scope, company_id),
    do: from(p in Tenancy.scope_query(Policy, scope), where: p.company_id == ^company_id)

  defp view(row),
    do:
      Map.take(
        row,
        ~w(id code version name effective_from rules status actor_user_id published_by_user_id published_at)a
      )

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)
end
