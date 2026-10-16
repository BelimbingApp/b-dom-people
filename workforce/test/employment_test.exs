defmodule Bilimbi.People.Workforce.EmploymentTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions
  alias Bilimbi.People.Workforce.Employment
  alias Bilimbi.People.Workforce.EmploymentOwner
  alias Bilimbi.People.Workforce.EmploymentRecord
  alias Bilimbi.People.Workforce.ProductionSeeds
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Workforce.TestFixtures, as: WorkforceFixtures

  @view "people.workforce.employment.view"
  @manage "people.workforce.employment.manage"
  @person_view "admin.person.view"

  setup do
    on_exit(&EmploymentOwner.unregister/0)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{descriptor: %{id: "people/workforce"}, payload: Contributions.contributions().settings}
      ])

    AuthorizationFixtures.install_snapshot!("people-workforce-employment-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    WorkforceFixtures.create_workforce_tables!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "Tenant A"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Tenant B", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    :ok = Employee.ensure_system_types()

    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Viewer", email: "v@example.com"})
    UserFixtures.insert_user!(%{id: 93, company_id: 73, name: "HR only", email: "h@example.com"})
    UserFixtures.insert_user!(%{id: 95, company_id: 75, name: "Outsider", email: "o@example.com"})
    operator = AuthorizationFixtures.sign_in!(scope, 73, 91, [@view, @manage, @person_view])
    viewer = AuthorizationFixtures.sign_in!(scope, 73, 92, [@view, @person_view])
    hr_only = AuthorizationFixtures.sign_in!(scope, 73, 93, [@view, @manage])
    outsider = AuthorizationFixtures.sign_in!(other_scope, 75, 95, [@view, @manage])

    {:ok, human} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-1",
        full_name: "Employee One",
        employee_type: "part_time",
        status: "probation",
        employment_start: ~D[2026-01-05],
        employment_end: ~D[2026-12-31],
        metadata: %{"grade" => "G3", "history" => [1, 2]}
      })

    {:ok, agent} =
      Employee.create_employee(scope, 73, %{
        employee_number: "A-1",
        full_name: "System Agent",
        employee_type: "agent"
      })

    {:ok, leaver} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-2",
        full_name: "Employee Two",
        status: "terminated",
        employment_end: ~D[2025-06-30]
      })

    %{
      scope: scope,
      operator: operator,
      viewer: viewer,
      hr_only: hr_only,
      outsider: outsider,
      human: human,
      agent: agent,
      leaver: leaver
    }
  end

  test "a claim copies every Core HR row verbatim with an explicit person mapping", ctx do
    assert {:ok, %{claimed: 3, adopted: 0, unchanged: 0, unclaimed: []}} =
             Workforce.reconcile_employments(ctx.operator, 73)

    for core <- [ctx.human, ctx.agent, ctx.leaver] do
      assert {:ok, identity} = Employee.person_identity(ctx.scope, core.id)

      assert {:ok, %ReadResult{freshness: :current, value: %Employment{} = employment}} =
               Workforce.employment(ctx.viewer, 73, core.id)

      assert employment.source == :people
      assert employment.employee_id == core.id
      assert employment.platform_company_id == 73
      assert employment.person_id == identity.person_id
      assert employment.affiliation_id == identity.affiliation_id
      assert employment.employee_number == core.employee_number
      assert employment.employment_type == core.employee_type
      assert employment.status == core.status
      assert employment.employment_start == core.employment_start
      assert employment.employment_end == core.employment_end
      assert employment.metadata == core.metadata
    end

    assert {:ok, %ReadResult{value: %{total: 3, people: 3, legacy_drift: 0, core_legacy: 0}}} =
             Workforce.employment_summary(ctx.viewer, 73)

    assert {:ok, %{claimed: 0, adopted: 0, unchanged: 3, unclaimed: []}} =
             Workforce.reconcile_employments(ctx.operator, 73)
  end

  test "an unclaimed employee reads Core's values and Core's person mapping", ctx do
    assert {:ok, identity} = Employee.person_identity(ctx.scope, ctx.human.id)

    assert {:ok, %ReadResult{value: employment}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert employment.source == :core_legacy
    assert employment.status == "probation"
    assert employment.person_id == identity.person_id
    assert employment.affiliation_id == identity.affiliation_id

    assert {:ok, %ReadResult{value: %{total: 3, people: 0, core_legacy: 3}}} =
             Workforce.employment_summary(ctx.viewer, 73)
  end

  test "a People change is written through to Core in the same transaction", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    assert {:ok, %Employment{} = employment} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{
               "status" => "active",
               "employment_end" => nil,
               "employee_number" => " E-100 "
             })

    assert employment.source == :people
    assert employment.status == "active"
    assert employment.employee_number == "E-100"
    assert employment.employment_end == nil

    assert {:ok, core} = Employee.get_employee(ctx.scope, 73, ctx.human.id)
    assert {core.status, core.employee_number, core.employment_end} == {"active", "E-100", nil}

    record = Repo.get_by!(EmploymentRecord, legacy_employee_id: ctx.human.id)

    assert {record.status, record.employee_number, record.employment_end} ==
             {"active", "E-100", nil}

    assert {:ok, %ReadResult{value: [value]}} = Workforce.employees(ctx.scope, 73)
    assert value.employee_number == "E-100"
  end

  test "a People change claims an unclaimed employee", ctx do
    assert {:ok, %Employment{source: :people, status: "inactive"}} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{status: "inactive"})

    assert {:ok, %ReadResult{value: %{people: 1, core_legacy: 2}}} =
             Workforce.employment_summary(ctx.viewer, 73)
  end

  test "an invalid or Core-refused change writes nothing anywhere", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    assert {:error, %Ecto.Changeset{} = invalid} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{
               status: "retired",
               employment_end: ~D[2025-01-01]
             })

    assert %{status: [_], employment_end: [_]} = errors(invalid)

    assert {:error, %Ecto.Changeset{} = refused} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{
               employment_type: "unknown_type"
             })

    assert %{employment_type: [_]} = errors(refused)

    assert {:ok, core} = Employee.get_employee(ctx.scope, 73, ctx.human.id)
    assert {core.status, core.employee_type} == {"probation", "part_time"}

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "probation"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)
  end

  test "a Core-side change after the claim is read as drift and adopted by reconcile", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    {:ok, _core} = Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "inactive"})

    assert {:ok, %ReadResult{value: %Employment{source: :legacy_drift, status: "inactive"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: []}} = Workforce.employees(ctx.scope, 73)

    assert {:ok, %ReadResult{value: %{legacy_drift: 1, people: 2}}} =
             Workforce.employment_summary(ctx.viewer, 73)

    assert {:ok, %{claimed: 0, adopted: 1, unchanged: 2}} =
             Workforce.reconcile_employments(ctx.operator, 73)

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "inactive"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)
  end

  test "employment reads and writes are authorized for the scope's actor now", ctx do
    assert {:error, :unauthorized} = Workforce.reconcile_employments(ctx.viewer, 73)
    assert {:error, :unauthorized} = Workforce.reconcile_employments(ctx.scope, 73)

    assert {:error, :unauthorized} =
             Workforce.update_employment(ctx.viewer, 73, ctx.human.id, %{status: "active"})

    assert {:ok, %ReadResult{value: %{people: 0}}} = Workforce.employment_summary(ctx.viewer, 73)

    :ok = AuthorizationFixtures.revoke!(ctx.scope, 73, 92, @view)
    assert {:error, :unauthorized} = Workforce.employment(ctx.viewer, 73, ctx.human.id)
    assert {:error, :unauthorized} = Workforce.employment_summary(ctx.viewer, 73)

    assert {:error, reason} = Workforce.reconcile_employments(ctx.outsider, 73)
    assert reason in [:unauthorized, :not_found]
    assert {:error, :not_found} = Workforce.employment(ctx.outsider, 75, ctx.human.id)

    assert {:ok, core} = Employee.get_employee(ctx.scope, 73, ctx.human.id)
    assert core.status == "probation"
  end

  test "claiming needs Core's contact view, because Core gates the person mapping", ctx do
    assert {:error, :unauthorized} = Workforce.reconcile_employments(ctx.hr_only, 73)

    assert {:error, :unauthorized} =
             Workforce.update_employment(ctx.hr_only, 73, ctx.human.id, %{status: "active"})

    assert {:ok, core} = Employee.get_employee(ctx.scope, 73, ctx.human.id)
    assert core.status == "probation"

    assert {:ok, %ReadResult{value: %Employment{source: :core_legacy, person_id: nil}}} =
             Workforce.employment(ctx.hr_only, 73, ctx.human.id)

    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    assert {:ok, %Employment{source: :people, status: "active"}} =
             Workforce.update_employment(ctx.hr_only, 73, ctx.human.id, %{status: "active"})
  end

  test "the owner seam is registered only when Core offers it", _ctx do
    refute EmploymentOwner.registered?()
    assert {:error, :unavailable} = EmploymentOwner.register(Enum)
    refute EmploymentOwner.registered?()

    assert :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)
    assert_received {:registered, EmploymentOwner}
    assert EmploymentOwner.registered?()

    assert :ok = EmploymentOwner.unregister()
    assert_received {:unregistered, EmploymentOwner}
    refute EmploymentOwner.registered?()
  end

  test "with the owner registered a claimed row is People's and Core's writes reach it", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)
    :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)

    {:ok, _core} = Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "inactive"})

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "probation"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert :ok = EmploymentOwner.legacy_employee_written(ctx.scope, written(ctx, ctx.human))

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "inactive"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: %{people: 3, legacy_drift: 0}}} =
             Workforce.employment_summary(ctx.viewer, 73)
  end

  test "registering adopts a Core edit made before, so People reads it at once", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    {:ok, _core} =
      Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "terminated"})

    assert {:ok, %ReadResult{value: %Employment{source: :legacy_drift, status: "terminated"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "terminated"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: []}} = Workforce.employees(ctx.scope, 73)

    assert {:ok, %ReadResult{value: %{people: 3, legacy_drift: 0}}} =
             Workforce.employment_summary(ctx.viewer, 73)
  end

  test "Core's write claims an unclaimed row without a contact grant on its actor", ctx do
    assert :ok =
             EmploymentOwner.legacy_employee_written(
               ctx.hr_only,
               Map.put(written(ctx, ctx.human), :added_later, true)
             )

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "probation"}}} =
             Workforce.employment(ctx.hr_only, 73, ctx.human.id)
  end

  test "an overlay shows the facts People resolves over Core's summaries", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)
    :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)
    {:ok, core} = Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "inactive"})

    assert [%{status: "probation", employee_number: "E-1"}] =
             Workforce.with_employment_facts(ctx.scope, [core])

    :ok = EmploymentOwner.unregister()

    assert [%{status: "inactive"}] = Workforce.with_employment_facts(ctx.scope, [core])
  end

  test "a conflicting claim is reported and the rest of the company is claimed", ctx do
    {:ok, identity} = Employee.person_identity(ctx.scope, ctx.human.id)
    conflicting = insert_record!(ctx.human, identity, legacy_employee_id: 900_001)

    assert {:ok, %{claimed: 2, unclaimed: [{human_id, :duplicate_affiliation}]}} =
             Workforce.reconcile_employments(ctx.operator, 73)

    assert human_id == ctx.human.id

    assert {:ok, %ReadResult{value: [exception]}} =
             Workforce.employment_exceptions(ctx.viewer, 73)

    assert %{employee_id: ^human_id, employee_number: "E-1", reason: :duplicate_affiliation} =
             exception

    assert {:error, :duplicate_affiliation} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{status: "active"})

    assert {:ok, core} = Employee.get_employee(ctx.scope, 73, ctx.human.id)
    assert core.status == "probation"

    Repo.delete!(conflicting)

    assert {:ok, %{claimed: 1, unchanged: 2, unclaimed: []}} =
             Workforce.reconcile_employments(ctx.operator, 73)

    assert {:ok, %ReadResult{value: []}} = Workforce.employment_exceptions(ctx.viewer, 73)
  end

  test "exceptions are readable only with the employment view capability", ctx do
    assert {:error, :unauthorized} = Workforce.employment_exceptions(ctx.scope, 73)
    assert {:error, reason} = Workforce.employment_exceptions(ctx.outsider, 73)
    assert reason in [:unauthorized, :not_found]

    :ok = AuthorizationFixtures.revoke!(ctx.scope, 73, 92, @view)
    assert {:error, :unauthorized} = Workforce.employment_exceptions(ctx.viewer, 73)
  end

  test "the production seed claims every live company in every tenant", ctx do
    {:ok, other_employee} =
      Employee.create_employee(elem(Tenancy.scope(42), 1), 75, %{
        employee_number: "C-1",
        full_name: "Other Tenant Employee"
      })

    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Frozen", code: "frozen"})

    {:ok, frozen} =
      Employee.create_employee(ctx.scope, 74, %{employee_number: "F-1", full_name: "Frozen"})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE companies SET status = 'archived' WHERE id = 74", [])

    assert :ok = ProductionSeeds.backfill(Repo)
    assert :ok = ProductionSeeds.backfill(Repo)

    assert {:ok, %ReadResult{value: %{total: 3, people: 3}}} =
             Workforce.employment_summary(ctx.viewer, 73)

    assert {:ok, %ReadResult{value: %Employment{source: :people, employee_number: "C-1"}}} =
             Workforce.employment(ctx.outsider, 75, other_employee.id)

    assert Repo.get_by(EmploymentRecord, legacy_employee_id: frozen.id) == nil
  end

  test "the seed provider is registered with the module", _ctx do
    assert Application.fetch_env!(:bilimbi_people_workforce, :bilimbi_production_seed_provider) ==
             ProductionSeeds

    behaviours =
      ProductionSeeds.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Bilimbi.Base.Database.ProductionSeedProvider in behaviours
  end

  defp insert_record!(core, identity, overrides) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(
      struct!(
        EmploymentRecord,
        Keyword.merge(
          [
            tenant_id: 41,
            company_id: core.company_id,
            legacy_employee_id: core.id,
            person_id: identity.person_id,
            affiliation_id: identity.affiliation_id,
            employee_number: core.employee_number,
            employment_type: core.employee_type,
            status: core.status,
            claimed_at: now
          ],
          overrides
        )
      )
    )
  end

  test "Core's write of a row it cannot map is recorded, and Core's write stands", ctx do
    assert :ok =
             EmploymentOwner.legacy_employee_written(ctx.scope, %{
               employee_id: ctx.human.id,
               person_id: nil,
               affiliation_id: nil
             })

    assert {:ok, %ReadResult{value: %Employment{source: :core_legacy}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: [%{employee_id: id, reason: :no_person_mapping}]}} =
             Workforce.employment_exceptions(ctx.viewer, 73)

    assert id == ctx.human.id
  end

  test "registering adopts a Core write made while Core was being registered", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)

    Process.put(:during_registration, fn ->
      {:ok, _core} =
        Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "terminated"})
    end)

    assert :ok = EmploymentOwner.register(__MODULE__.WritingSeamCore)

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "terminated"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: []}} = Workforce.employees(ctx.scope, 73)
  end

  test "the grace pass adopts writes in flight at registration and claims new rows", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)
    assert EmploymentOwner.grace_pass_child() == nil

    assert :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)

    assert %{id: {EmploymentOwner, :grace_pass}, restart: :temporary} =
             EmploymentOwner.grace_pass_child()

    # In flight: Core committed these after it accepted the owner, without
    # reaching the callback.
    {:ok, _core} =
      Employee.update_employee(ctx.scope, 73, ctx.human.id, %{status: "terminated"})

    {:ok, hire} =
      Employee.create_employee(ctx.scope, 73, %{employee_number: "E-9", full_name: "New Hire"})

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "probation"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert :ok = EmploymentOwner.run_grace_pass()

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "terminated"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)

    assert {:ok, %ReadResult{value: %Employment{source: :people, employee_number: "E-9"}}} =
             Workforce.employment(ctx.viewer, 73, hire.id)

    assert :ok = EmploymentOwner.run_grace_pass()

    assert {:ok, %ReadResult{value: %{people: 4, core_legacy: 0}}} =
             Workforce.employment_summary(ctx.viewer, 73)
  end

  test "the grace pass never reverts a People write newer than Core's", ctx do
    {:ok, _report} = Workforce.reconcile_employments(ctx.operator, 73)
    assert :ok = EmploymentOwner.register(WorkforceFixtures.SeamCore)

    assert {:ok, %Employment{status: "active"}} =
             Workforce.update_employment(ctx.operator, 73, ctx.human.id, %{status: "active"})

    assert :ok = EmploymentOwner.run_grace_pass()

    assert {:ok, %ReadResult{value: %Employment{source: :people, status: "active"}}} =
             Workforce.employment(ctx.viewer, 73, ctx.human.id)
  end

  defmodule WritingSeamCore do
    @moduledoc false
    # A Core with the seam that sees a deprecated HR write land while it
    # registers the owner, after People's registration-time backfill.
    def register_employment_owner(_owner) do
      Process.get(:during_registration).()
      :ok
    end

    def unregister_employment_owner(_owner), do: :ok
  end

  defp written(ctx, core) do
    {:ok, identity} = Employee.person_identity(ctx.scope, core.id)

    %{
      employee_id: core.id,
      person_id: identity.person_id,
      affiliation_id: identity.affiliation_id
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
