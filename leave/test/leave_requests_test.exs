defmodule Bilimbi.People.LeaveRequestsTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.DateTime.Contributions, as: DateTimeContributions
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.CarryForwardWorker
  alias Bilimbi.People.Leave.Contributions
  alias Bilimbi.People.Leave.TestFixtures
  alias Bilimbi.People.ReferenceData
  alias Bilimbi.People.ReferenceData.TestFixtures, as: ReferenceFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  # 2099-03-02 is a Monday; far-future dates keep these tests independent of
  # today, since requests have no forward limit.
  @monday ~D[2099-03-02]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{descriptor: %{id: "people/leave"}, payload: Contributions.contributions().settings},
        %{
          descriptor: %{id: "base/datetime"},
          payload: DateTimeContributions.contributions().settings
        }
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "leave-requests-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    ReferenceFixtures.create_reference_tables!()
    TestFixtures.create_leave_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    {:ok, approver_employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-2", full_name: "Employee Two"})

    UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})

    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      employee_id: approver_employee.id,
      email: "approver@example.com"
    })

    {:ok, type} =
      Leave.create_type(scope, 73, %{code: "annual", name: "Annual", unit: "day", paid: true})

    %{
      scope: scope,
      other_scope: other_scope,
      employee: employee,
      type: type,
      requester: %{type: :user, id: 91, company_id: 73},
      approver: %{type: :user, id: 92, company_id: 73}
    }
  end

  defp fund(scope, employee, type, on, quantity) do
    {:ok, _} =
      Leave.record_entry(scope, 73, employee.id, %{
        leave_type_id: type.id,
        entry_type: "opening",
        quantity: quantity,
        occurred_on: on,
        source: "operator",
        entry_key: "fund-#{type.id}-#{on}"
      })

    :ok
  end

  defp request(scope, actor, type, starts_on, ends_on, extra \\ %{}) do
    Leave.submit_request(
      scope,
      73,
      actor,
      Map.merge(
        %{
          leave_type_id: type.id,
          starts_on: starts_on,
          ends_on: ends_on,
          request_key: "key-#{System.unique_integer([:positive])}"
        },
        extra
      )
    )
  end

  defp balance(scope, employee, year) do
    {:ok, [row]} = Leave.balances(scope, 73, employee.id, year)
    row
  end

  test "counts working weekdays outside calendar exceptions and reserves them", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 10)

    {:ok, _} =
      ReferenceData.create_calendar_exception(scope, 73, %{
        on_date: Date.add(@monday, 2),
        label: "Closure"
      })

    assert {:ok, %{status: "pending", quantity: quantity, leave_year: 2099}} =
             request(scope, requester, type, @monday, Date.add(@monday, 6))

    assert Decimal.equal?(quantity, 4)

    row = balance(scope, employee, 2099)
    assert Decimal.equal?(row.balance, 10)
    assert Decimal.equal?(row.pending, 4)
    assert Decimal.equal?(row.available, 6)

    assert {:error, :no_working_days} =
             request(scope, requester, type, Date.add(@monday, 5), Date.add(@monday, 6))
  end

  test "working weekdays and backdating are company request rules", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 10)

    assert {:ok, %{working_weekdays: [1, 2, 3, 4, 5], backdate_days: 30}} =
             Leave.request_rules(scope, 73)

    assert {:ok, %{working_weekdays: [6, 7], backdate_days: 0}} =
             Leave.put_request_rules(scope, 73, %{working_weekdays: [7, 6, 6], backdate_days: 0})

    assert {:ok, %{working_weekdays: [1, 2, 3, 4, 5]}} = Leave.request_rules(scope, 74)

    assert {:ok, %{quantity: quantity}} =
             request(scope, requester, type, @monday, Date.add(@monday, 6))

    assert Decimal.equal?(quantity, 2)

    {:ok, today} = Leave.today(scope, 73)

    assert {:error, :too_far_back} =
             request(scope, requester, type, Date.add(today, -1), Date.add(today, -1))

    for bad <- [
          %{working_weekdays: [], backdate_days: 1},
          %{working_weekdays: [8], backdate_days: 1},
          %{working_weekdays: [1], backdate_days: 367}
        ] do
      assert {:error, :invalid_rules} = Leave.put_request_rules(scope, 73, bad)
    end
  end

  test "a replayed request key returns the request; a changed one is refused", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 10)
    attrs = %{leave_type_id: type.id, starts_on: @monday, ends_on: @monday, request_key: "k1"}

    assert {:ok, first} = Leave.submit_request(scope, 73, requester, attrs)
    assert {:ok, ^first} = Leave.submit_request(scope, 73, requester, attrs)

    assert {:error, :request_key_conflict} =
             Leave.submit_request(scope, 73, requester, %{attrs | ends_on: Date.add(@monday, 1)})

    assert {:ok, [_]} = Leave.self_requests(scope, 73, requester)
  end

  test "live requests never overlap, but the two halves of a day may be separate", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 10)

    assert {:ok, %{quantity: half}} =
             request(scope, requester, type, @monday, @monday, %{day_part: "am"})

    assert Decimal.equal?(half, Decimal.new("0.5"))
    assert {:ok, _} = request(scope, requester, type, @monday, @monday, %{day_part: "pm"})

    assert {:error, :overlapping_request} =
             request(scope, requester, type, @monday, Date.add(@monday, 1))

    assert {:error, :invalid_request} =
             request(scope, requester, type, @monday, Date.add(@monday, 1), %{day_part: "am"})

    assert {:error, :invalid_request} =
             request(scope, requester, type, @monday, @monday, %{day_part: "hours", hours: "2"})
  end

  test "the database refuses a second live claim on the same half day", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 10)
    {:ok, request} = request(scope, requester, type, @monday, @monday)

    %{rows: [[other_id]]} =
      Repo.query!(
        """
        INSERT INTO people_leave_requests
          (tenant_id, company_id, employee_id, leave_type_id, leave_year, starts_on, ends_on,
           day_part, quantity, unit, status, request_key, requested_by_user_id,
           inserted_at, updated_at)
        SELECT tenant_id, company_id, employee_id, leave_type_id, leave_year, starts_on, ends_on,
           'am', 0.5, unit, 'pending', 'raw', requested_by_user_id, inserted_at, updated_at
        FROM people_leave_requests WHERE id = $1
        RETURNING id
        """,
        [request.id]
      )

    assert_raise Postgrex.Error, ~r/people_leave_request_days_am_unique/, fn ->
      Repo.query!(
        """
        INSERT INTO people_leave_request_days
          (tenant_id, company_id, employee_id, request_id, on_date, am, pm, quantity, active)
        SELECT tenant_id, company_id, employee_id, id, starts_on, true, false, 0.5, true
        FROM people_leave_requests WHERE id = $1
        """,
        [other_id]
      )
    end
  end

  test "balance, leave year and hour units are enforced", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx
    fund(scope, employee, type, @monday, 1)

    assert {:error, :insufficient_balance} =
             request(scope, requester, type, @monday, Date.add(@monday, 1))

    assert {:error, :spans_leave_years} =
             request(scope, requester, type, ~D[2099-12-31], ~D[2100-01-01])

    {:ok, hourly} =
      Leave.create_type(scope, 73, %{
        code: "time-off",
        name: "Time off",
        unit: "hour",
        paid: false,
        balance_required: false
      })

    assert {:ok, %{quantity: hours, unit: "hour"}} =
             request(scope, requester, hourly, @monday, @monday, %{
               day_part: "hours",
               hours: "2.5"
             })

    assert Decimal.equal?(hours, Decimal.new("2.5"))

    row =
      Enum.find(
        elem(Leave.balances(scope, 73, employee.id, 2099), 1),
        &(&1.leave_type.id == hourly.id)
      )

    assert Decimal.equal?(row.available, Decimal.new("-2.5"))

    assert {:error, :invalid_request} =
             request(scope, requester, hourly, @monday, @monday, %{day_part: "full"})
  end

  test "an independent approver approves and the ledger records the taken leave", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester, approver: approver} =
      ctx

    fund(scope, employee, type, @monday, 5)
    {:ok, pending} = request(scope, requester, type, @monday, Date.add(@monday, 1))

    assert {:error, :self_approval} =
             Leave.decide_request(scope, 73, requester, pending.id, :approve, nil)

    assert {:ok, [%{employee_name: "Employee One (E-1)"}]} = Leave.pending_requests(scope, 73)

    assert {:ok, %{status: "approved", decided_by_user_id: 92}} =
             Leave.decide_request(scope, 73, approver, pending.id, :approve, nil)

    assert {:error, :not_pending} =
             Leave.decide_request(scope, 73, approver, pending.id, :approve, nil)

    row = balance(scope, employee, 2099)
    assert Decimal.equal?(row.taken, 2)
    assert Decimal.equal?(row.balance, 3)
    assert Decimal.equal?(row.pending, 0)

    assert {:ok, entries} = Leave.entries(scope, 73, employee.id, 2099)
    assert %{quantity: taken, source: "request"} = Enum.find(entries, &(&1.entry_type == "taken"))
    assert Decimal.equal?(taken, -2)
    assert {:ok, []} = Leave.pending_requests(scope, 73)
  end

  test "an approver whose user cannot be resolved is refused", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester} = ctx

    fund(scope, employee, type, @monday, 5)
    {:ok, pending} = request(scope, requester, type, @monday, @monday)

    assert {:error, :self_approval} =
             Leave.decide_request(
               scope,
               73,
               %{type: :user, id: 999, company_id: 73},
               pending.id,
               :approve,
               nil
             )

    assert {:ok, [%{id: id}]} = Leave.pending_requests(scope, 73)
    assert id == pending.id
  end

  test "operator entries cannot use the module's own ledger sources", ctx do
    %{scope: scope, employee: employee, type: type} = ctx

    for source <- ~w(policy request carry_forward) do
      assert {:error, :invalid_entry} =
               Leave.record_entry(scope, 73, employee.id, %{
                 leave_type_id: type.id,
                 entry_type: "adjustment",
                 quantity: 1,
                 occurred_on: @monday,
                 source: source,
                 entry_key: "carry:#{type.id}:#{employee.id}:2099"
               })
    end
  end

  test "rejection needs a note and frees the dates", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester, approver: approver} =
      ctx

    fund(scope, employee, type, @monday, 5)
    {:ok, pending} = request(scope, requester, type, @monday, @monday)

    assert {:error, :note_required} =
             Leave.decide_request(scope, 73, approver, pending.id, :reject, "  ")

    assert {:ok, %{status: "rejected", decision_note: "Team is short"}} =
             Leave.decide_request(scope, 73, approver, pending.id, :reject, "Team is short")

    assert {:ok, _} = request(scope, requester, type, @monday, @monday)
    assert Decimal.equal?(balance(scope, employee, 2099).balance, 5)
  end

  test "approval rechecks the balance", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester, approver: approver} =
      ctx

    fund(scope, employee, type, @monday, 2)
    {:ok, pending} = request(scope, requester, type, @monday, Date.add(@monday, 1))

    {:ok, _} =
      Leave.record_entry(scope, 73, employee.id, %{
        leave_type_id: type.id,
        entry_type: "adjustment",
        quantity: -1,
        occurred_on: @monday,
        source: "operator",
        entry_key: "correction"
      })

    assert {:error, :insufficient_balance} =
             Leave.decide_request(scope, 73, approver, pending.id, :approve, nil)
  end

  test "cancelling returns pending and future approved leave, not started leave", ctx do
    %{scope: scope, employee: employee, type: type, requester: requester, approver: approver} =
      ctx

    fund(scope, employee, type, @monday, 5)
    {:ok, pending} = request(scope, requester, type, @monday, @monday)
    assert {:ok, %{status: "cancelled"}} = Leave.cancel_request(scope, 73, requester, pending.id)
    assert {:error, :not_cancellable} = Leave.cancel_request(scope, 73, requester, pending.id)

    {:ok, approved} = request(scope, requester, type, @monday, Date.add(@monday, 1))
    {:ok, _} = Leave.decide_request(scope, 73, approver, approved.id, :approve, nil)
    assert Decimal.equal?(balance(scope, employee, 2099).balance, 3)

    assert {:error, :not_found} = Leave.cancel_request(scope, 73, approver, approved.id)
    assert {:ok, %{status: "cancelled"}} = Leave.cancel_request(scope, 73, requester, approved.id)

    row = balance(scope, employee, 2099)
    assert Decimal.equal?(row.balance, 5) and Decimal.equal?(row.taken, 0)

    {:ok, today} = Leave.today(scope, 73)
    fund(scope, employee, type, today, 5)

    {:ok, _} =
      Leave.put_request_rules(scope, 73, %{
        working_weekdays: Enum.to_list(1..7),
        backdate_days: 30
      })

    {:ok, started} = request(scope, requester, type, today, today)
    {:ok, _} = Leave.decide_request(scope, 73, approver, started.id, :approve, nil)
    assert {:error, :not_cancellable} = Leave.cancel_request(scope, 73, requester, started.id)
  end

  test "requests are scoped to the actor's company and tenant", ctx do
    %{scope: scope, other_scope: other, type: type, requester: requester, approver: approver} =
      ctx

    fund(scope, ctx.employee, type, @monday, 1)
    {:ok, pending} = request(scope, requester, type, @monday, @monday)

    assert {:error, :unavailable} =
             Leave.submit_request(scope, 74, requester, %{
               leave_type_id: type.id,
               starts_on: @monday,
               request_key: "x"
             })

    assert {:error, :not_found} =
             Leave.decide_request(scope, 74, approver, pending.id, :approve, nil)

    assert {:error, :not_found} = Leave.pending_requests(other, 73)

    assert {:error, :not_found} =
             Leave.decide_request(other, 73, approver, pending.id, :approve, nil)
  end

  describe "carry-forward" do
    # The previous leave year ends on the last day of the month before today,
    # so pending requests in it stay inside the backdating window.
    setup %{scope: scope} do
      {:ok, today} = Leave.today(scope, 73)
      {:ok, _} = Leave.put_rules(scope, 73, today.month)

      {:ok, _} =
        Leave.put_request_rules(scope, 73, %{
          working_weekdays: Enum.to_list(1..7),
          backdate_days: 366
        })

      year = today.year - 1
      {first_next, _} = Leave.year_range(%{year_start_month: today.month}, year + 1)
      %{year: year, last_day: Date.add(first_next, -1), first_next: first_next}
    end

    test "carries up to the cap, expires the rest and closes the year", ctx do
      %{scope: scope, employee: employee, type: type, requester: requester, year: year} = ctx

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{
          effective_from: Date.new!(1990, 1, 1),
          entitlement: 10,
          carry_forward_cap: "4"
        })

      {:ok, %{granted: 2}} = Leave.grant_entitlements(scope, 73, year)

      assert {:error, :year_not_ended} = Leave.carry_forward(scope, 73, year + 1)

      assert {:ok, %{carried: 2, existing: 0, pending: 0}} =
               Leave.carry_forward(scope, 73, year, 92)

      assert {:ok, %{carried: 0, existing: 2}} = Leave.carry_forward(scope, 73, year, 92)
      assert {:ok, 2} = Leave.carried_forward_count(scope, 73, year)

      closed = balance(scope, employee, year)
      assert Decimal.equal?(closed.expired, 6) and Decimal.equal?(closed.balance, 4)

      assert Decimal.equal?(balance(scope, employee, year + 1).carried_forward, 4)

      assert {:error, :year_closed} =
               request(scope, requester, type, ctx.last_day, ctx.last_day)

      assert {:error, :year_closed} =
               Leave.record_entry(scope, 73, employee.id, %{
                 leave_type_id: type.id,
                 entry_type: "adjustment",
                 quantity: 1,
                 occurred_on: ctx.last_day,
                 source: "operator",
                 entry_key: "late"
               })

      assert {:ok, _} = request(scope, requester, type, ctx.first_next, ctx.first_next)
    end

    test "refuses to carry into a next year already closed", ctx do
      %{scope: scope, employee: employee, type: type, year: year} = ctx

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{
          effective_from: Date.new!(1990, 1, 1),
          entitlement: 10,
          carry_forward_cap: "4"
        })

      {:ok, %{granted: 2}} = Leave.grant_entitlements(scope, 73, year - 1)
      assert {:ok, %{carried: 2}} = Leave.carry_forward(scope, 73, year, 92)

      assert {:error, :next_year_closed} = Leave.carry_forward(scope, 73, year - 1, 92)
      assert {:ok, 0} = Leave.carried_forward_count(scope, 73, year - 1)
      assert Decimal.equal?(balance(scope, employee, year).carried_forward, 0)
    end

    test "a late grant skips a year already carried forward", ctx do
      %{scope: scope, employee: employee, type: type, year: year} = ctx

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{
          effective_from: Date.new!(1990, 1, 1),
          entitlement: 10,
          carry_forward_cap: "4"
        })

      assert {:ok, %{carried: 2}} = Leave.carry_forward(scope, 73, year, 92)

      assert {:ok, %{granted: 0, existing: 0, closed: 2}} =
               Leave.grant_entitlements(scope, 73, year)

      assert Decimal.equal?(balance(scope, employee, year).balance, 0)
    end

    test "skips pending requests and types without a cap", ctx do
      %{
        scope: scope,
        employee: employee,
        type: type,
        requester: requester,
        approver: approver,
        year: year
      } = ctx

      {:ok, _} =
        Leave.add_policy(scope, 73, type.id, %{
          effective_from: Date.new!(1990, 1, 1),
          entitlement: 3,
          carry_forward_cap: 5
        })

      {:ok, uncapped} =
        Leave.create_type(scope, 73, %{code: "other", name: "Other", unit: "day", paid: true})

      {:ok, _} =
        Leave.add_policy(scope, 73, uncapped.id, %{
          effective_from: Date.new!(1990, 1, 1),
          entitlement: 3
        })

      {:ok, %{granted: 4}} = Leave.grant_entitlements(scope, 73, year)

      {:ok, pending} = request(scope, requester, type, ctx.last_day, ctx.last_day)
      assert {:ok, %{carried: 1, pending: 1}} = Leave.carry_forward(scope, 73, year)

      {:ok, _} = Leave.decide_request(scope, 73, approver, pending.id, :approve, nil)
      assert {:ok, %{carried: 1, existing: 1}} = Leave.carry_forward(scope, 73, year)
      assert Decimal.equal?(balance_for(scope, employee, type, year + 1).carried_forward, 2)
      assert Decimal.equal?(balance_for(scope, employee, uncapped, year + 1).carried_forward, 0)
      assert Decimal.equal?(balance_for(scope, employee, uncapped, year).balance, 3)
    end

    test "the worker validates its arguments and needs a signed-in operator", ctx do
      assert {:ok, %{"company_id" => 73, "from_year" => 2025}} =
               CarryForwardWorker.validate_args(%{
                 "company_id" => 73,
                 "from_year" => 2025,
                 "x" => 1
               })

      assert {:error, :invalid_carry_forward} =
               CarryForwardWorker.validate_args(%{"company_id" => "73", "from_year" => 2025})

      assert {:cancel, :not_authorized} =
               CarryForwardWorker.handle_job(%{"company_id" => 73, "from_year" => ctx.year}, %{
                 scope: nil
               })

      assert {:cancel, :not_authorized} =
               CarryForwardWorker.handle_job(%{"company_id" => 73, "from_year" => ctx.year}, %{
                 scope: ctx.scope
               })
    end
  end

  defp balance_for(scope, employee, type, year) do
    {:ok, rows} = Leave.balances(scope, 73, employee.id, year)
    Enum.find(rows, &(&1.leave_type.id == type.id))
  end
end
