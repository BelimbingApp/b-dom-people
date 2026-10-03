defmodule Bilimbi.People.Workforce.AuthorizationTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Workforce.Authorization
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions

  @capability "people.workforce.settings.manage"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{descriptor: %{id: "people/workforce"}, payload: Contributions.contributions().settings}
      ])

    AuthorizationFixtures.install_snapshot!("people-workforce-authorization-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "Tenant A"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Tenant B", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    {:ok, leaver} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-2",
        full_name: "Employee Two",
        status: "terminated"
      })

    UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "unlinked@example.com"})

    UserFixtures.insert_user!(%{
      id: 93,
      company_id: 73,
      employee_id: leaver.id,
      email: "leaver@example.com"
    })

    %{scope: scope, employee: employee}
  end

  test "authorize evaluates the capability now, for the scope's actor and company", %{
    scope: scope
  } do
    assert {:error, :unauthorized} = Authorization.authorize(scope, 73, @capability)
    refute Authorization.allowed?(scope, 73, @capability)

    actor_scope = AuthorizationFixtures.sign_in(scope, 91, 73)
    assert {:error, :unauthorized} = Authorization.authorize(actor_scope, 73, @capability)

    :ok = AuthorizationFixtures.grant!(scope, 73, 91, @capability)
    assert {:ok, actor} = Authorization.authorize(actor_scope, 73, @capability)
    assert %{type: :user, id: 91, company_id: 73} = actor
    assert Authorization.allowed?(actor_scope, 73, @capability)

    # The grant is per company; a sibling company is out of reach and a
    # company the tenant cannot see is not found.
    assert {:error, :unauthorized} = Authorization.authorize(actor_scope, 74, @capability)
    assert {:error, :not_found} = Authorization.authorize(actor_scope, 75, @capability)
    assert {:error, :not_found} = Authorization.authorize(actor_scope, "73", @capability)

    :ok = AuthorizationFixtures.revoke!(scope, 73, 91, @capability)
    assert {:error, :unauthorized} = Authorization.authorize(actor_scope, 73, @capability)
  end

  test "self_employee resolves the current link to a working employee", %{
    scope: scope,
    employee: employee
  } do
    assert {:error, :not_linked} = Authorization.self_employee(scope, 73)

    linked = AuthorizationFixtures.sign_in(scope, 91, 73)
    assert {:ok, employee_id} = Authorization.self_employee(linked, 73)
    assert employee_id == employee.id
    assert {:error, :not_linked} = Authorization.self_employee(linked, 74)

    assert {:error, :not_linked} =
             Authorization.self_employee(AuthorizationFixtures.sign_in(scope, 92, 73), 73)

    assert {:error, :not_linked} =
             Authorization.self_employee(AuthorizationFixtures.sign_in(scope, 93, 73), 73)

    assert {:ok, _user} = User.update_user(scope, 73, 91, %{employee_id: nil})
    assert {:error, :not_linked} = Authorization.self_employee(linked, 73)
  end

  test "authorize_self needs both the capability and a current link", %{
    scope: scope,
    employee: employee
  } do
    linked = AuthorizationFixtures.sign_in(scope, 91, 73)
    assert {:error, :unauthorized} = Authorization.authorize_self(linked, 73, @capability)

    :ok = AuthorizationFixtures.grant!(scope, 73, 91, @capability)

    assert {:ok, %{actor: %{id: 91}, employee_id: id}} =
             Authorization.authorize_self(linked, 73, @capability)

    assert id == employee.id

    unlinked = AuthorizationFixtures.sign_in!(scope, 73, 92, @capability)
    assert {:error, :not_linked} = Authorization.authorize_self(unlinked, 73, @capability)
  end

  test "with_self_employee_lock proves the link again under the affiliation lock", %{
    scope: scope,
    employee: employee
  } do
    linked = AuthorizationFixtures.sign_in!(scope, 73, 91, @capability)

    assert {:ok, {true, id}} =
             Authorization.with_self_employee_lock(linked, 73, @capability, fn self ->
               {:ok, {Repo.in_transaction?(), self.employee_id}}
             end)

    assert id == employee.id

    assert {:error, :refused} =
             Authorization.with_self_employee_lock(linked, 73, @capability, fn _self ->
               {:error, :refused}
             end)

    # The link is removed while the page that resolved it stays open: the
    # next write finds no employee to act for.
    assert {:ok, _user} = User.update_user(scope, 73, 91, %{employee_id: nil})

    assert {:error, :not_linked} =
             Authorization.with_self_employee_lock(linked, 73, @capability, fn _self ->
               flunk("the write must not run for an unlinked account")
             end)

    # Relinked to another employee: the operation acts on that employee only.
    {:ok, other} =
      Employee.create_employee(scope, 73, %{employee_number: "E-3", full_name: "Employee Three"})

    assert {:ok, _user} = User.update_user(scope, 73, 91, %{employee_id: other.id})

    assert {:ok, other_id} =
             Authorization.with_self_employee_lock(linked, 73, @capability, fn self ->
               {:ok, self.employee_id}
             end)

    assert other_id == other.id

    :ok = AuthorizationFixtures.revoke!(scope, 73, 91, @capability)

    assert {:error, :unauthorized} =
             Authorization.with_self_employee_lock(linked, 73, @capability, fn _self ->
               flunk("the write must not run without the grant")
             end)
  end
end
