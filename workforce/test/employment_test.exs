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
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.People.Workforce.TestFixtures, as: WorkforceFixtures

  @view "people.workforce.employment.view"
  @manage "people.workforce.employment.manage"
  @person_view "admin.person.view"

  setup do
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

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
