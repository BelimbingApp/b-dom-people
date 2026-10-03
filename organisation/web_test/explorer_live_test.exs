defmodule Bilimbi.People.Organisation.Web.ExplorerLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Organisation
  alias Bilimbi.People.Organisation.PositionAssignment
  alias Bilimbi.People.Organisation.TestFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures

  @manage "people.organisation.manage"

  setup do
    UserFixtures.create_user_tables!()
    TestFixtures.create_position_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok = Employee.ensure_system_types()
    {:ok, system} = Tenancy.scope(41)

    # Seed data is written by a separate manager account, so each test grants
    # the signed-in user 91 exactly the capabilities it exercises.
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Seeder", email: "s@example.com"})
    scope = AuthorizationFixtures.sign_in!(system, 73, 92, [@manage])
    %{scope: scope, system: system}
  end

  test "the authorised explorer shows empty state and company-scoped positions", %{
    conn: conn,
    scope: scope
  } do
    grant_capabilities!("people.organisation.view")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/people/organisation")
    assert has_element?(view, "#organisation-empty")

    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-1"})

    {:ok, _} =
      Organisation.record_version(scope, 73, position.id, %{
        version: 1,
        title: "Position Alpha",
        effective_from: ~D[2026-01-01]
      })

    assert render_patch(view, ~p"/people/organisation?as_of=2026-09-30") =~ "Position Alpha"
    refute has_element?(view, "#organisation-empty")

    refute render_patch(view, ~p"/people/organisation?company_id=73&page=5") =~ "Position Alpha"
    refute has_element?(view, "#organisation-empty")

    refute render_patch(view, ~p"/people/organisation?company_id=74") =~ "Position Alpha"
  end

  test "a manager ends an assignment from the explorer and the action is audited", %{
    conn: conn,
    scope: scope
  } do
    grant_capabilities!(["people.organisation.view", "people.organisation.manage"])
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-END"})

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-END", full_name: "Holder"})

    {:ok, assignment} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: employee.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/people/organisation?company_id=73&as_of=2026-09-30")

    view
    |> form("#end-assignment-#{assignment.id}", %{effective_to: "2026-09-30"})
    |> render_submit()

    assert %PositionAssignment{effective_to: ~D[2026-09-30]} =
             Repo.get(PositionAssignment, assignment.id)

    assert {:ok, actions} = Audit.list_actions(scope)

    assert [ended] = Enum.filter(actions, &(&1.event == "people.organisation.assignment_ended"))
    assert ended.actor_id == 91
    assert ended.payload["assignment_id"] == assignment.id

    render_patch(view, ~p"/people/organisation?company_id=73&as_of=2026-10-01")
    refute has_element?(view, "#end-assignment-#{assignment.id}")
  end

  test "ending an assignment requires the manage capability", %{
    conn: conn,
    scope: scope,
    system: system
  } do
    grant_capabilities!("people.organisation.view")
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-VIEW"})

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-VIEW", full_name: "Holder"})

    {:ok, assignment} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: employee.id,
        kind: "acting",
        effective_from: ~D[2026-01-01]
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/people/organisation?company_id=73&as_of=2026-09-30")

    assert render(view) =~ "Employee #{employee.id}"
    refute has_element?(view, "#end-assignment-#{assignment.id}")

    viewer = AuthorizationFixtures.sign_in(system, 91, 73)

    assert {:error, :unauthorized} =
             Organisation.end_assignment(viewer, 73, assignment.id, ~D[2026-09-30])

    assert %PositionAssignment{effective_to: nil} = Repo.get(PositionAssignment, assignment.id)
  end

  test "ending an assignment after the grant is revoked changes nothing", %{
    conn: conn,
    scope: scope,
    system: system
  } do
    grant_capabilities!(["people.organisation.view", @manage])
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-REVOKED"})

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-REV", full_name: "Holder"})

    {:ok, assignment} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: employee.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/people/organisation?company_id=73&as_of=2026-09-30")

    assert has_element?(view, "#end-assignment-#{assignment.id}")

    assert {:ok, :stored} =
             Authz.put_principal_capability(system, 73, :user, 91, @manage, false)

    assert render_hook(view, "end_assignment", %{
             "assignment_id" => Integer.to_string(assignment.id),
             "effective_to" => "2026-09-30"
           }) =~ "You no longer have permission to change this company"

    assert %PositionAssignment{effective_to: nil} = Repo.get(PositionAssignment, assignment.id)
    assert {:ok, []} = Audit.list_actions(system)
  end

  test "ending an assignment after only the view grant is revoked changes nothing", %{
    conn: conn,
    scope: scope,
    system: system
  } do
    grant_capabilities!(["people.organisation.view", @manage])
    {:ok, position} = Organisation.create_position(scope, 73, %{code: "P-REVOKED"})

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-REV", full_name: "Holder"})

    {:ok, assignment} =
      Organisation.assign(scope, 73, position.id, %{
        employee_id: employee.id,
        kind: "substantive",
        effective_from: ~D[2026-01-01]
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/people/organisation?company_id=73&as_of=2026-09-30")

    assert has_element?(view, "#end-assignment-#{assignment.id}")

    assert {:ok, :stored} =
             Authz.put_principal_capability(
               system,
               73,
               :user,
               91,
               "people.organisation.view",
               false
             )

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             render_hook(view, "end_assignment", %{
               "assignment_id" => Integer.to_string(assignment.id),
               "effective_to" => "2026-09-30"
             })

    assert %PositionAssignment{effective_to: nil} = Repo.get(PositionAssignment, assignment.id)
    assert {:ok, []} = Audit.list_actions(system)
  end

  test "route refuses an actor without the capability", %{conn: conn} do
    assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live(~p"/people/organisation")
  end
end
