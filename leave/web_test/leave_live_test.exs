defmodule BilimbiWeb.LeaveLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Leave
  alias Bilimbi.Base.Repo
  alias Bilimbi.People.Leave.CarryForwardWorker
  alias Bilimbi.People.Leave.TestFixtures, as: LeaveFixtures
  alias Bilimbi.People.ReferenceData.TestFixtures, as: ReferenceFixtures

  test "leave pages require authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/leave/my")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/leave/policies")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/leave/requests")
  end

  describe "linked account" do
    setup do
      UserFixtures.create_user_tables!()
      SettingsFixtures.create_settings_table!()
      LeaveFixtures.create_leave_tables!()
      ReferenceFixtures.create_reference_tables!()
      CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
      CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
      {:ok, scope} = Tenancy.scope(41)
      :ok = Employee.ensure_system_types()

      {:ok, employee} =
        Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

      {:ok, colleague} =
        Employee.create_employee(scope, 73, %{employee_number: "E-2", full_name: "Employee Two"})

      UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})

      UserFixtures.insert_user!(%{
        id: 92,
        company_id: 73,
        employee_id: colleague.id,
        email: "approver@example.com"
      })

      grant_capabilities!([
        "people.leave.self.view",
        "people.leave.policies.manage",
        "people.leave.requests.approve"
      ])

      grant_capabilities!(["people.leave.requests.approve"], user_id: 92)
      %{scope: scope, employee: employee}
    end

    test "self view shows an empty state before any leave type exists", %{conn: conn} do
      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/my")
      assert has_element?(view, "#my-leave-no-types")
    end

    test "operator adds a type and version, grants, and the employee sees the balance", %{
      conn: conn
    } do
      conn = log_in_as(conn)
      {:ok, view, _} = live(conn, "/people/leave/policies")
      assert has_element?(view, "#leave-types-empty")
      assert has_element?(view, "#leave-policies-none")

      view
      |> form("#leave-type-form", type: %{code: "annual", name: "Annual leave", unit: "day"})
      |> render_submit()

      assert render(view) =~ "Leave type added."
      assert has_element?(view, "#leave-types", "Annual leave")

      year = Date.utc_today().year

      view
      |> form("#leave-policy-form", policy: %{effective_from: "#{year}-01-01", entitlement: "14"})
      |> render_submit()

      assert render(view) =~ "Policy version added."
      assert has_element?(view, "#leave-policy-versions", "14.00")

      view |> form("#leave-grant-form", leave_year: "#{year}") |> render_submit()
      assert render(view) =~ "2 entitlements granted; 0 were already granted."

      {:ok, my, _} = live(conn, "/people/leave/my")
      assert has_element?(my, "#my-leave-balances", "Annual leave")
      assert has_element?(my, "#my-leave-balances", "14.00")
    end

    test "the leave year is locked once balances exist", %{conn: conn, scope: scope} do
      {:ok, type} =
        Leave.create_type(scope, 73, %{code: "annual", name: "Annual", unit: "day", paid: true})

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2020-01-01], entitlement: 5})

      {:ok, _} = Leave.grant_entitlements(scope, 73, 2020)

      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/policies")
      view |> form("#leave-year-form", year_start_month: "4") |> render_submit()
      assert render(view) =~ "The leave year cannot change after balances have been recorded."
    end

    test "an employee requests leave, an independent approver approves, the balance updates",
         %{conn: conn, scope: scope, employee: employee} do
      {:ok, type} =
        Leave.create_type(scope, 73, %{code: "annual", name: "Annual", unit: "day", paid: true})

      {:ok, today} = Leave.today(scope, 73)

      {:ok, _} =
        Leave.record_entry(scope, 73, employee.id, %{
          leave_type_id: type.id,
          entry_type: "opening",
          quantity: 5,
          occurred_on: today,
          source: "operator",
          entry_key: "opening"
        })

      {:ok, _} =
        Leave.put_request_rules(scope, 73, %{
          working_weekdays: Enum.to_list(1..7),
          backdate_days: 30
        })

      employee_conn = log_in_as(conn)
      {:ok, my, _} = live(employee_conn, "/people/leave/my")
      assert has_element?(my, "#my-leave-no-requests")

      my
      |> form("#leave-request-form",
        request: %{leave_type_id: type.id, starts_on: Date.to_iso8601(today), day_part: "am"}
      )
      |> render_submit()

      assert render(my) =~ "Leave request submitted."
      assert has_element?(my, "#my-leave-requests", "pending")
      assert has_element?(my, "#my-leave-balances", "4.50")

      my
      |> form("#leave-request-form",
        request: %{leave_type_id: type.id, starts_on: Date.to_iso8601(today)}
      )
      |> render_submit()

      assert render(my) =~
               "Another pending or approved request already covers part of these dates."

      {:ok, own_queue, _} = live(employee_conn, "/people/leave/requests")
      [request] = elem(Leave.pending_requests(scope, 73), 1)

      own_queue
      |> form("#leave-decision-#{request.id}")
      |> render_submit(%{"decision" => "approve"})

      assert render(own_queue) =~ "You cannot decide your own leave request."

      approver_conn = log_in_as(build_conn(), session_user(%{"user_id" => 92}))
      {:ok, queue, _} = live(approver_conn, "/people/leave/requests")
      assert has_element?(queue, "#leave-approval-#{request.id}", "Employee One (E-1)")

      queue
      |> form("#leave-decision-#{request.id}")
      |> render_submit(%{"decision" => "reject"})

      assert render(queue) =~ "Give a reason when rejecting a request."

      queue
      |> form("#leave-decision-#{request.id}")
      |> render_submit(%{"decision" => "approve"})

      assert render(queue) =~ "Leave request approved."
      assert has_element?(queue, "#leave-approvals-none")

      {:ok, my, _} = live(employee_conn, "/people/leave/my")
      assert has_element?(my, "#my-leave-requests", "approved")
      assert has_element?(my, "#my-leave-balances", "4.50")
    end

    test "the operator sets request rules and queues carry-forward", %{
      conn: conn,
      scope: scope
    } do
      {:ok, today} = Leave.today(scope, 73)
      {:ok, _} = Leave.put_rules(scope, 73, today.month)

      {:ok, type} =
        Leave.create_type(scope, 73, %{code: "annual", name: "Annual", unit: "day", paid: true})

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{
          effective_from: ~D[1990-01-01],
          entitlement: 10,
          carry_forward_cap: 3
        })

      {:ok, %{granted: 2}} = Leave.grant_entitlements(scope, 73, today.year - 1)

      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/policies")
      assert has_element?(view, "#leave-policy-versions", "3.00")

      view
      |> form("#leave-request-rules-form", %{working_weekdays: ["1", "2"], backdate_days: "5"})
      |> render_submit()

      assert render(view) =~ "Request rules saved."
      assert {:ok, %{working_weekdays: [1, 2], backdate_days: 5}} = Leave.request_rules(scope, 73)

      view |> form("#leave-carry-forward-form", from_year: "#{today.year - 1}") |> render_submit()
      assert render(view) =~ "Carry-forward queued."

      job =
        Repo.one!(
          from(j in Oban.Job,
            where: j.worker == ^inspect(CarryForwardWorker.__queue_worker__().adapter)
          )
        )

      assert :ok = CarryForwardWorker.__queue_worker__().adapter.perform(job)
      assert {:ok, 2} = Leave.carried_forward_count(scope, 73, today.year - 1)

      {:ok, view, _} = conn |> log_in_as() |> live("/people/leave/policies")
      assert has_element?(view, "#leave-carried-count", "2 balances")
      refute has_element?(view, "#leave-carry-skipped")
    end
  end
end
