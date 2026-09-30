defmodule Bilimbi.People.Performance do
  @moduledoc """
  Scoped position descriptions, KPI targets and evidence-backed performance
  reviews. Corrections append versions. Public results are schema-free maps;
  competence, progression and pay remain separate workflows.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias Bilimbi.Base.{Authz, Repo, Tenancy}
  alias Bilimbi.Base.Authz.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.Audit.Context
  alias Bilimbi.Core.{Company, User}
  alias Bilimbi.People.{Organisation, Skills, Workforce}
  alias Bilimbi.People.Workforce.ReadResult

  alias Bilimbi.People.Performance.{
    Description,
    Definition,
    Target,
    Observation,
    Review,
    ReviewObservation,
    ReviewTarget,
    Response
  }

  @view "people.performance.view"
  @self "people.performance.self.view"
  @description "people.performance.descriptions.manage"
  @target "people.performance.kpis.submit"
  @review "people.performance.reviews.submit"

  def allowed?(%Scope{} = scope, company_id, capability) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         %{allowed: true} <- Authz.can(scope, capability),
         {:ok, _} <- Company.authorize_company_target(actor, company_id, capability),
         do: true,
         else: (_ -> false)
  end

  def allowed?(_, _, _), do: false

  @doc "An immutable draft linked to exact position and published competency versions."
  def draft_description(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @description, fn actor ->
      fields =
        ~w(code version position_id position_version effective_from effective_to purpose responsibilities duties authority qualifications competency_links)a

      cs = build(Description, actor, company_id, attrs, fields, fields -- [:effective_to])
      row = valid!(cs)
      validate_description!(actor.scope, company_id, row)
      insert(cs)
    end)
  end

  def publish_description(%Scope{} = scope, company_id, id) do
    write(scope, company_id, @description, fn actor ->
      row = get!(Description, actor.scope, company_id, id)
      require!(row.status == "draft", :not_pending)
      validate_description!(actor.scope, company_id, row)

      overlap =
        from(d in scoped(Description, actor.scope, company_id),
          where:
            d.position_id == ^row.position_id and d.status == "published" and
              (is_nil(d.effective_to) or d.effective_to >= ^row.effective_from)
        )

      overlap =
        if row.effective_to,
          do: where(overlap, [d], d.effective_from <= ^row.effective_to),
          else: overlap

      require!(!Repo.exists?(overlap), :overlapping_description)
      transition(row, status: "published", published_at: now(), published_by_user_id: actor.id)
    end)
  end

  @doc "An immutable measurement definition. Calculation versions are provenance, never executable formulas."
  def define_kpi(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @target, fn actor ->
      fields =
        ~w(code version name purpose unit measure source_reference calculation_version direction rubric precision interpretation)a

      cs =
        build(Definition, actor, company_id, attrs, fields, fields -- [:rubric])
        |> validate_inclusion(:direction, ~w(higher lower band rubric))
        |> validate_number(:precision, greater_than_or_equal_to: 0, less_than_or_equal_to: 8)

      row = valid!(cs)
      require!(row.direction != "rubric" or present?(row.rubric), :rubric_required)
      insert(cs)
    end)
  end

  @doc "A proposed individual target for a direct report, retaining the definition version."
  def propose_target(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @target, fn actor ->
      fields =
        ~w(definition_id employee_id target period_start period_end effective_from confidential)a

      cs = build(Target, actor, company_id, attrs, fields, fields)
      row = valid!(cs)
      require_report!(actor, company_id, row.employee_id)
      definition = get!(Definition, actor.scope, company_id, row.definition_id)
      require_period!(row.period_start, row.period_end)

      require!(
        Date.compare(row.effective_from, row.period_start) != :lt and
          Date.compare(row.effective_from, row.period_end) != :gt,
        :invalid_dates
      )

      cs |> put_change(:definition_version, definition.version) |> insert()
    end)
  end

  def amend_target(%Scope{} = scope, company_id, id, attrs) when is_map(attrs) do
    write(scope, company_id, @target, fn actor ->
      prior = get!(Target, actor.scope, company_id, id)
      require_report!(actor, company_id, prior.employee_id)
      require!(prior.status == "published", :not_released)
      require!(!successor?(Target, actor.scope, company_id, prior.id), :already_corrected)

      cs =
        build(
          Target,
          actor,
          company_id,
          attrs,
          ~w(target effective_from change_reason)a,
          ~w(target effective_from change_reason)a
        )

      row = valid!(cs)

      require!(
        Date.compare(row.effective_from, prior.effective_from) == :gt and
          Date.compare(row.effective_from, prior.period_end) != :gt,
        :invalid_dates
      )

      cs
      |> change(
        Map.take(
          Map.from_struct(prior),
          ~w(definition_id definition_version employee_id period_start period_end confidential)a
        )
      )
      |> change(version: prior.version + 1, supersedes_id: prior.id)
      |> insert()
    end)
  end

  def review_target(%Scope{} = scope, company_id, id, note) do
    write(scope, company_id, "people.performance.kpis.review", fn actor ->
      row = get!(Target, actor.scope, company_id, id)
      require!(row.status == "proposed", :not_pending)
      independent!(actor, company_id, row)
      require!(present?(note), :reason_required)

      transition(row,
        status: "reviewed",
        review_note: String.trim(note),
        reviewed_by_user_id: actor.id
      )
    end)
  end

  def publish_target(%Scope{} = scope, company_id, id) do
    write(scope, company_id, "people.performance.kpis.approve", fn actor ->
      row = get!(Target, actor.scope, company_id, id)
      require!(row.status == "reviewed" and not row.confidential, :not_publishable)
      independent!(actor, company_id, row)
      current_employee!(actor.scope, company_id, row.employee_id)
      transition(row, status: "published", published_at: now(), published_by_user_id: actor.id)
    end)
  end

  def record_observation(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @review, fn actor ->
      fields = ~w(employee_id window_start window_end evidence source_reference source_version)a
      cs = build(Observation, actor, company_id, attrs, fields, fields)
      row = valid!(cs)
      require_report!(actor, company_id, row.employee_id)
      require_period!(row.window_start, row.window_end)
      insert(cs)
    end)
  end

  def correct_observation(%Scope{} = scope, company_id, id, attrs) when is_map(attrs) do
    write(scope, company_id, @review, fn actor ->
      prior = get!(Observation, actor.scope, company_id, id)
      require!(prior.actor_user_id == actor.id, :not_author)
      require_report!(actor, company_id, prior.employee_id)
      require!(!successor?(Observation, actor.scope, company_id, prior.id), :already_corrected)

      cs =
        build(
          Observation,
          actor,
          company_id,
          attrs,
          ~w(evidence source_version change_reason)a,
          ~w(evidence source_version change_reason)a
        )

      valid!(cs)

      cs
      |> change(
        Map.take(
          Map.from_struct(prior),
          ~w(employee_id window_start window_end source_reference)a
        )
      )
      |> put_change(:supersedes_id, prior.id)
      |> insert()
    end)
  end

  @doc "Pins exact observations and communicated targets at an explicit UTC cutoff."
  def draft_review(%Scope{} = scope, company_id, attrs) when is_map(attrs),
    do:
      write(scope, company_id, @review, fn actor ->
        create_review(actor, company_id, attrs, nil)
      end)

  def correct_review(%Scope{} = scope, company_id, id, attrs) when is_map(attrs) do
    write(scope, company_id, @review, fn actor ->
      prior = get!(Review, actor.scope, company_id, id)
      require!(prior.actor_user_id == actor.id and prior.status == "released", :not_author)
      require!(!successor?(Review, actor.scope, company_id, prior.id), :already_corrected)
      create_review(actor, company_id, attrs, prior)
    end)
  end

  @doc "Releases a fully evidenced draft independently of author and subject."
  def release_review(%Scope{} = scope, company_id, id) do
    write(scope, company_id, "people.performance.reviews.approve", fn actor ->
      row = get!(Review, actor.scope, company_id, id)
      require!(row.status == "draft", :not_pending)
      independent!(actor, company_id, row)
      require!(DateTime.compare(row.cutoff_at, now()) != :gt, :future_cutoff)
      description = get!(Description, actor.scope, company_id, row.description_id)
      validate_assignment!(actor.scope, company_id, row, description)

      require!(
        Repo.exists?(
          from(o in scoped(ReviewObservation, actor.scope, company_id), where: o.review_id == ^id)
        ) and
          Repo.exists?(
            from(t in scoped(ReviewTarget, actor.scope, company_id), where: t.review_id == ^id)
          ),
        :evidence_required
      )

      transition(row, status: "released", released_at: now(), released_by_user_id: actor.id)
    end)
  end

  def respond(%Scope{} = scope, company_id, id, response) do
    write(scope, company_id, @self, fn actor ->
      employee_id = self_employee!(actor, company_id)
      row = get!(Review, actor.scope, company_id, id)
      require!(row.employee_id == employee_id and row.status == "released", :not_found)

      build(Response, actor, company_id, %{response: response}, [:response], [:response])
      |> change(review_id: row.id, employee_id: employee_id)
      |> insert()
    end)
  end

  @doc "Actor-specific authored review index with bounded pagination."
  def reviews(%Scope{} = scope, company_id, opts \\ []) do
    with {:ok, actor} <- authorize(scope, company_id, @view) do
      page(
        from(r in scoped(Review, actor.scope, company_id), where: r.actor_user_id == ^actor.id),
        opts
      )
    end
  end

  @doc "Original evidence and responses under the current actor's authorization."
  def review(%Scope{} = scope, company_id, id) do
    with {:ok, actor} <- authorize(scope, company_id, @view),
         row when not is_nil(row) <- get(Review, actor.scope, company_id, id),
         true <-
           (row.actor_user_id == actor.id or
              allowed?(actor.scope, company_id, "people.performance.reviews.approve")) and
             (row.status == "released" or
                linked_employee(actor, company_id) != {:ok, row.employee_id}) do
      {:ok, review_view(actor.scope, company_id, row)}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Only this login actor's linked employee's released reviews and communicated targets."
  def my_records(%Scope{} = scope, company_id, opts \\ []) do
    with {:ok, actor} <- authorize(scope, company_id, @self),
         {:ok, employee_id} <- self_employee(actor, company_id),
         {:ok, result} <-
           page(
             from(r in scoped(Review, actor.scope, company_id),
               where: r.employee_id == ^employee_id and r.status == "released"
             ),
             opts
           ) do
      targets =
        scoped(Target, actor.scope, company_id)
        |> where(
          [t],
          t.employee_id == ^employee_id and t.status == "published" and not t.confidential
        )
        |> records()

      {:ok,
       %{
         reviews: %{
           result
           | rows: Enum.map(result.rows, &review_view(actor.scope, company_id, &1))
         },
         targets: targets
       }}
    end
  end

  @doc """
  Bounded planning records. Author scope is retained for observations and review
  lists; records about the viewer's own linked employee are never listed here.
  """
  def planning_records(%Scope{} = scope, company_id) do
    with {:ok, actor} <- authorize(scope, company_id, @view) do
      can? = &allowed?(actor.scope, company_id, &1)
      own = linked_employee(actor, company_id)
      subject = &not_subject(scoped(&1, actor.scope, company_id), own)

      definitions =
        if can?.(@target), do: records(scoped(Definition, actor.scope, company_id)), else: []

      descriptions =
        if can?.(@description),
          do: scoped(Description, actor.scope, company_id),
          else: where(scoped(Description, actor.scope, company_id), [d], d.status == "published")

      targets =
        cond do
          can?.("people.performance.kpis.review") or can?.("people.performance.kpis.approve") ->
            records(subject.(Target))

          can?.(@target) ->
            records(where(subject.(Target), [t], t.actor_user_id == ^actor.id))

          true ->
            []
        end

      drafts =
        if can?.("people.performance.reviews.approve"),
          do: records(where(subject.(Review), [r], r.status == "draft")),
          else: []

      {:ok,
       %{
         definitions: definitions,
         descriptions: records(descriptions),
         targets: targets,
         observations: records(where(subject.(Observation), [o], o.actor_user_id == ^actor.id)),
         drafts: drafts,
         prior_reviews:
           records(
             where(subject.(Review), [r], r.actor_user_id == ^actor.id and r.status == "released")
           )
       }}
    end
  end

  @doc "Human-readable planning choices through Workforce, Organisation and Skills public contracts."
  def planning_choices(%Scope{} = scope, company_id) do
    with {:ok, actor} <- authorize(scope, company_id, @view),
         {:ok, read} <- Workforce.employees(actor.scope, company_id),
         {:ok, employees} <- ReadResult.require_current(read),
         {:ok, positions} <- Organisation.positions(actor.scope, company_id),
         {:ok, profiles} <- Skills.list_profiles(actor.scope, company_id) do
      own =
        case self_employee(actor, company_id) do
          {:ok, id} -> to_string(id)
          _ -> nil
        end

      reports =
        Enum.filter(
          employees,
          &(own != nil and &1.supervisor_reference != nil and
              &1.supervisor_reference.stable_id == own)
        )

      report_ids = Enum.map(reports, &String.to_integer(&1.reference.stable_id))

      targets =
        if allowed?(actor.scope, company_id, @target) or
             allowed?(actor.scope, company_id, @review),
           do:
             scoped(Target, actor.scope, company_id)
             |> where([t], t.status == "published" and t.employee_id in ^report_ids)
             |> records(),
           else: []

      {:ok,
       %{
         employees:
           Enum.map(
             reports,
             &%{id: String.to_integer(&1.reference.stable_id), name: &1.display_name}
           ),
         descriptions:
           scoped(Description, actor.scope, company_id)
           |> where([d], d.status == "published")
           |> records(),
         targets: targets,
         positions:
           Enum.map(
             positions,
             &%{
               id: String.to_integer(&1.reference.stable_id),
               name: &1.title || &1.code,
               version: &1.version
             }
           ),
         profiles: Enum.filter(profiles, &(&1.status == "published")),
         names: Map.new(employees, &{String.to_integer(&1.reference.stable_id), &1.display_name})
       }}
    end
  end

  defp create_review(actor, company_id, attrs, prior) do
    fields =
      ~w(employee_id description_id period_start period_end cutoff_at outcome rationale change_reason)a

    attrs = stringify(attrs)

    attrs =
      if prior && attrs["cutoff_at"] in [nil, ""],
        do: Map.put(attrs, "cutoff_at", prior.cutoff_at),
        else: attrs

    attrs =
      if prior,
        do:
          Map.merge(
            attrs,
            Map.new(
              Map.take(
                Map.from_struct(prior),
                ~w(employee_id period_start period_end)a
              ),
              fn {k, v} -> {to_string(k), v} end
            )
          ),
        else: attrs

    cs = build(Review, actor, company_id, attrs, fields, fields -- [:change_reason])
    row = valid!(cs)
    require_report!(actor, company_id, row.employee_id)
    require_period!(row.period_start, row.period_end)
    require!(Date.compare(DateTime.to_date(row.cutoff_at), row.period_end) != :lt, :invalid_dates)
    description = get!(Description, actor.scope, company_id, row.description_id)

    require!(
      description.status == "published" and
        Date.compare(description.effective_from, row.period_start) != :gt and
        (is_nil(description.effective_to) or
           Date.compare(description.effective_to, row.period_end) != :lt),
      :description_unavailable
    )

    validate_assignment!(actor.scope, company_id, row, description)

    if prior do
      require!(present?(row.change_reason), :reason_required)
      require!(DateTime.compare(row.cutoff_at, prior.cutoff_at) != :lt, :invalid_dates)
    end

    cs =
      if prior,
        do: change(cs, version: prior.version + 1, supersedes_id: prior.id),
        else: put_change(cs, :change_reason, nil)

    observations = ids!(attrs["observation_ids"])
    targets = ids!(attrs["target_ids"])
    require!(observations != [] and targets != [], :evidence_required)

    for id <- observations do
      o = get!(Observation, actor.scope, company_id, id)

      require!(
        o.employee_id == row.employee_id and Date.compare(o.window_start, row.period_start) != :lt and
          Date.compare(o.window_end, row.period_end) != :gt and
          DateTime.compare(o.inserted_at, row.cutoff_at) != :gt,
        :evidence_outside_window
      )
    end

    for id <- targets do
      t = get!(Target, actor.scope, company_id, id)

      require!(
        t.employee_id == row.employee_id and t.status == "published" and not t.confidential and
          t.period_start == row.period_start and t.period_end == row.period_end and
          DateTime.compare(t.published_at, row.cutoff_at) != :gt,
        :target_unavailable
      )
    end

    review = insert(cs)

    for id <- observations,
        do: pin(ReviewObservation, actor, company_id, review.id, :observation_id, id)

    for id <- targets, do: pin(ReviewTarget, actor, company_id, review.id, :target_id, id)
    review
  end

  defp validate_description!(scope, company_id, row) do
    require_period!(row.effective_from, row.effective_to || row.effective_from)
    position = position!(scope, company_id, row.position_id, row.effective_from)
    require!(position.version == row.position_version, :position_version_unavailable)

    require!(
      is_map(row.competency_links) and is_list(row.competency_links["profiles"]) and
        row.competency_links["profiles"] != [],
      :profile_unavailable
    )

    for link <- row.competency_links["profiles"] do
      require!(
        is_map(link) and Enum.sort(Map.keys(link)) == ["id", "version"],
        :profile_unavailable
      )

      case Skills.get_profile(scope, company_id, link["id"]) do
        {:ok, profile} ->
          require!(
            profile.status == "published" and profile.version == link["version"],
            :profile_unavailable
          )

        _ ->
          Repo.rollback(:profile_unavailable)
      end
    end
  end

  defp validate_assignment!(scope, company_id, row, description) do
    current_employee!(scope, company_id, row.employee_id)

    for day <- Enum.uniq([row.period_start, row.period_end]) do
      position = position!(scope, company_id, description.position_id, day)

      require!(
        position.version == description.position_version and not position.assignments_incomplete? and
          Enum.any?(
            position.assignments,
            &(&1.employee_reference.stable_id == to_string(row.employee_id))
          ),
        :assignment_unavailable
      )
    end
  end

  defp position!(scope, company_id, id, day, page \\ 1) do
    case Organisation.positions(scope, company_id, day, page: page, page_size: 100) do
      {:ok, rows} ->
        case Enum.find(rows, &(String.to_integer(&1.reference.stable_id) == id)) do
          nil when length(rows) == 100 -> position!(scope, company_id, id, day, page + 1)
          nil -> Repo.rollback(:position_unavailable)
          row -> row
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp require_report!(actor, company_id, id) do
    employee = current_employee!(actor.scope, company_id, id)
    own_id = self_employee!(actor, company_id)

    require!(
      employee.supervisor_reference != nil and
        employee.supervisor_reference.stable_id == to_string(own_id) and own_id != id,
      :out_of_reach
    )
  end

  defp independent!(actor, company_id, row) do
    require!(actor.id != row.actor_user_id, :self_approval)

    case linked_employee(actor, company_id) do
      {:ok, id} -> require!(id != row.employee_id, :self_approval)
      _ -> :ok
    end
  end

  defp linked_employee(actor, company_id) do
    with %Actor{type: :user, company_id: ^company_id} <- actor,
         {:ok, user} <- User.get_user(actor.scope, company_id, actor.id),
         id when is_integer(id) <- user.employee_id do
      {:ok, id}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp self_employee(actor, company_id) do
    with {:ok, id} <- linked_employee(actor, company_id),
         {:ok, read} <- Workforce.employee(actor.scope, company_id, id),
         {:ok, _employee} <- ReadResult.require_current(read) do
      {:ok, id}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp self_employee!(actor, company_id), do: unwrap!(self_employee(actor, company_id))

  defp current_employee!(scope, company_id, id) do
    with {:ok, read} <- Workforce.employee(scope, company_id, id),
         {:ok, employee} <- ReadResult.require_current(read) do
      employee
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize(%Scope{} = scope, company_id, capability) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         true <- allowed?(scope, company_id, capability),
         {:ok, read} <- Workforce.company(scope, company_id),
         {:ok, _company} <- ReadResult.require_current(read) do
      {:ok, actor}
    else
      false -> {:error, :unauthorized}
      {:error, :no_authenticated_actor} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp write(%Scope{} = scope, company_id, capability, fun) do
    with {:ok, actor} <- authorize(scope, company_id, capability),
         nil <- Scope.actor(scope).impersonator_id do
      context = Context.get()

      Context.put(%{
        context
        | actor_type: "user",
          actor_id: Scope.actor(scope).user_id,
          company_id: company_id,
          tenant_id: Scope.tenant_id(scope),
          impersonator_id: nil
      })

      try do
        Repo.transaction(fn ->
          unwrap!(Company.lock_live_company(scope, company_id))
          unwrap!(authorize(scope, company_id, capability))
          fun.(actor)
        end)
      rescue
        error in [Postgrex.Error, Ecto.ConstraintError] ->
          if constraint_error?(error),
            do: {:error, :invariant_refused},
            else: reraise(error, __STACKTRACE__)
      after
        Context.put(context)
      end
    else
      id when is_integer(id) -> {:error, :impersonation_refused}
      error -> error
    end
  end

  defp constraint_error?(%Ecto.ConstraintError{}), do: true

  defp constraint_error?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:check_violation, :unique_violation, :foreign_key_violation]

  defp constraint_error?(_), do: false
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)

  defp require_period!(first, last),
    do: require!(Date.compare(first, last) != :gt, :invalid_dates)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp ids!(ids) when is_list(ids) and length(ids) <= 100 do
    require!(Enum.all?(ids, &(is_integer(&1) and &1 > 0)), :invalid_evidence)
    Enum.uniq(ids)
  end

  defp ids!(_), do: Repo.rollback(:invalid_evidence)

  defp build(module, actor, company_id, attrs, fields, required) do
    attrs = attrs |> stringify() |> Map.take(Enum.map(fields, &to_string/1))

    attrs =
      if module == Description and is_list(attrs["competency_links"]),
        do: Map.update!(attrs, "competency_links", &%{"profiles" => &1}),
        else: attrs

    defaults =
      case module do
        Description -> %{status: "draft"}
        Target -> %{status: "proposed", version: 1}
        Review -> %{status: "draft", version: 1}
        _ -> %{}
      end

    row =
      struct(
        module,
        Map.merge(defaults, %{
          tenant_id: Scope.tenant_id(actor.scope),
          company_id: company_id,
          actor_user_id: actor.id
        })
      )

    cs = module.changeset(row, attrs) |> validate_required(required)

    Enum.reduce(fields, cs, fn field, cs ->
      value = get_field(cs, field)

      cond do
        is_binary(value) ->
          cs |> put_change(field, String.trim(value)) |> validate_length(field, max: 8000)

        field in [:version, :position_version] ->
          validate_number(cs, field, greater_than: 0)

        true ->
          cs
      end
    end)
  end

  defp valid!(cs), do: unwrap!(apply_action(cs, :insert))
  defp insert(cs), do: cs |> Repo.insert() |> unwrap!() |> view()
  defp transition(row, attrs), do: row |> change(attrs) |> Repo.update() |> unwrap!() |> view()

  defp pin(module, actor, company_id, review_id, field, id) do
    %{}
    |> Map.put(field, id)
    |> Map.put(:review_id, review_id)
    |> then(&build(module, actor, company_id, &1, [:review_id, field], [:review_id, field]))
    |> insert()
  end

  defp scoped(module, %Scope{} = scope, company_id),
    do: from(r in Tenancy.scope_query(module, scope), where: r.company_id == ^company_id)

  defp get(module, scope, company_id, id) when is_integer(id) and id > 0,
    do: scoped(module, scope, company_id) |> where([r], r.id == ^id) |> Repo.one()

  defp get(_module, _scope, _company_id, _id), do: nil

  defp get!(module, scope, company_id, id),
    do: get(module, scope, company_id, id) || Repo.rollback(:not_found)

  defp successor?(module, scope, company_id, id),
    do: Repo.exists?(from(r in scoped(module, scope, company_id), where: r.supersedes_id == ^id))

  defp records(query),
    do: query |> order_by([r], desc: r.id) |> limit(100) |> Repo.all() |> Enum.map(&view/1)

  defp not_subject(query, {:ok, id}), do: where(query, [r], r.employee_id != ^id)
  defp not_subject(query, _), do: query

  defp view(%{__struct__: _} = row),
    do: row |> Map.from_struct() |> Map.drop([:__meta__, :tenant_id, :company_id])

  defp view(row), do: row

  defp review_view(scope, company_id, row) do
    observations =
      from(o in scoped(Observation, scope, company_id),
        join: p in ReviewObservation,
        on: p.observation_id == o.id,
        where: p.review_id == ^row.id,
        order_by: [asc: o.id]
      )
      |> Repo.all()
      |> Enum.map(&view/1)

    targets =
      from(t in scoped(Target, scope, company_id),
        join: p in ReviewTarget,
        on: p.target_id == t.id,
        where: p.review_id == ^row.id,
        order_by: [asc: t.id]
      )
      |> Repo.all()
      |> Enum.map(&view/1)

    responses =
      scoped(Response, scope, company_id)
      |> where([r], r.review_id == ^row.id)
      |> order_by([r], asc: r.id)
      |> Repo.all()
      |> Enum.map(&view/1)

    row
    |> view()
    |> Map.merge(%{observations: observations, targets: targets, responses: responses})
  end

  defp page(query, opts) do
    page = Keyword.get(opts, :page, 1)
    size = Keyword.get(opts, :page_size, 25)

    if is_integer(page) and page > 0 and size in [10, 25, 50, 100] do
      total = Repo.aggregate(query, :count)
      page = min(page, max(1, ceil(total / size)))

      rows =
        query
        |> order_by([r], desc: r.id)
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
