defmodule Bilimbi.People.LeaveTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Leave
  alias Bilimbi.People.Leave.Contributions
  alias Bilimbi.People.Leave.TestFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{descriptor: %{id: "people/leave"}, payload: Contributions.contributions().settings}
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "leave-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    TestFixtures.create_leave_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    %{scope: scope, other_scope: other_scope, employee: employee}
  end

  defp annual_type(scope, company_id \\ 73) do
    {:ok, type} =
      Leave.create_type(scope, company_id, %{
        code: "annual",
        name: "Annual",
        unit: "day",
        paid: true
      })

    type
  end

  test "a new company has no leave types, policies, or balances", %{
    scope: scope,
    employee: employee
  } do
    assert {:ok, []} = Leave.list_types(scope, 73)
    assert {:ok, []} = Leave.list_policies(scope, 73)
    assert {:ok, []} = Leave.balances(scope, 73, employee.id, 2026)
    assert {:ok, %{year_start_month: 1}} = Leave.rules(scope, 73)
  end

  test "types are unique per company and validated", %{scope: scope} do
    annual_type(scope)

    assert {:error, %Ecto.Changeset{}} =
             Leave.create_type(scope, 73, %{
               code: "annual",
               name: "Again",
               unit: "day",
               paid: true
             })

    assert {:error, %Ecto.Changeset{}} =
             Leave.create_type(scope, 73, %{code: "Bad Code", name: "X", unit: "day", paid: true})

    assert {:error, %Ecto.Changeset{}} =
             Leave.create_type(scope, 73, %{code: "weeks", name: "X", unit: "week", paid: true})

    assert {:ok, %{code: "annual"}} =
             Leave.create_type(scope, 74, %{
               code: "annual",
               name: "Annual",
               unit: "day",
               paid: true
             })
  end

  test "policy versions are effective-dated and close their predecessor", %{scope: scope} do
    type = annual_type(scope)

    assert {:ok, %{version: 1, effective_to: nil}} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: ~D[2026-01-01],
               entitlement: "14"
             })

    assert {:error, :not_after_latest} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: ~D[2026-01-01],
               entitlement: "16"
             })

    assert {:ok, %{version: 2}} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: "2027-01-01",
               entitlement: "16.5"
             })

    assert {:ok, %{version: 1, effective_to: ~D[2026-12-31]}} =
             Leave.policy_on(scope, 73, type.id, ~D[2026-06-30])

    assert {:ok, %{version: 2, entitlement: entitlement}} =
             Leave.policy_on(scope, 73, type.id, ~D[2030-01-01])

    assert Decimal.equal?(entitlement, Decimal.new("16.5"))
    assert {:error, :not_found} = Leave.policy_on(scope, 73, type.id, ~D[2025-12-31])

    for bad <- ["-1", "10000", "1.005", "abc"] do
      assert {:error, _} =
               Leave.add_policy(scope, 73, type.id, %{
                 effective_from: "2028-01-01",
                 entitlement: bad
               })
    end
  end

  test "archived types take no new versions or grants", %{scope: scope, employee: employee} do
    type = annual_type(scope)

    {:ok, _} =
      Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2026-01-01], entitlement: 10})

    assert {:ok, %{status: "archived"}} = Leave.set_type_status(scope, 73, type.id, "archived")

    assert {:error, :not_found} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: ~D[2027-01-01],
               entitlement: 10
             })

    assert {:ok, %{granted: 0, existing: 0}} = Leave.grant_entitlements(scope, 73, 2026)
    assert {:ok, []} = Leave.balances(scope, 73, employee.id, 2026)
  end

  test "grants once per employee, type and year from the policy in force", %{
    scope: scope,
    employee: employee
  } do
    type = annual_type(scope)

    {:ok, _} =
      Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2026-01-01], entitlement: 14})

    assert {:ok, %{granted: 1, existing: 0}} = Leave.grant_entitlements(scope, 73, 2026, 91)
    assert {:ok, %{granted: 0, existing: 1}} = Leave.grant_entitlements(scope, 73, 2026, 91)
    assert {:ok, %{granted: 0, existing: 0}} = Leave.grant_entitlements(scope, 73, 2025)

    assert {:ok, [%{entitlement: entitlement, balance: balance}]} =
             Leave.balances(scope, 73, employee.id, 2026)

    assert Decimal.equal?(entitlement, 14) and Decimal.equal?(balance, 14)

    assert {:ok, [%{entry_type: "entitlement", policy_version: 1, occurred_on: ~D[2026-01-01]}]} =
             Leave.entries(scope, 73, employee.id, 2026)
  end

  test "repeated grants write no failed audit capture", %{scope: scope} do
    handler = "leave-audit-#{System.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:bilimbi, :base, :audit, :capture_failure],
      fn _, _, meta, _ -> send(test_pid, {:capture_failure, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    type = annual_type(scope)

    {:ok, _} =
      Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2026-01-01], entitlement: 14})

    assert {:ok, %{granted: 1}} = Leave.grant_entitlements(scope, 73, 2026)
    assert {:ok, %{existing: 1}} = Leave.grant_entitlements(scope, 73, 2026)
    refute_received {:capture_failure, _}
  end

  test "a version cannot start on or before an existing grant", %{scope: scope} do
    type = annual_type(scope)

    {:ok, _} =
      Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2026-01-01], entitlement: 14})

    {:ok, %{granted: 1}} = Leave.grant_entitlements(scope, 73, 2027)

    assert {:error, :granted_after_effective_date} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: ~D[2026-06-01],
               entitlement: 16
             })

    assert {:ok, %{version: 2}} =
             Leave.add_policy(scope, 73, type.id, %{
               effective_from: ~D[2027-01-02],
               entitlement: 16
             })
  end

  test "the leave year follows the company start month", %{scope: scope, employee: employee} do
    type = annual_type(scope)
    assert {:ok, %{year_start_month: 4}} = Leave.put_rules(scope, 73, 4)
    assert {:ok, %{year_start_month: 1}} = Leave.rules(scope, 74)
    assert Leave.leave_year(%{year_start_month: 4}, ~D[2027-03-31]) == 2026
    assert Leave.year_range(%{year_start_month: 4}, 2026) == {~D[2026-04-01], ~D[2027-03-31]}

    {:ok, _} =
      Leave.add_policy(scope, 73, type.id, %{effective_from: ~D[2026-04-01], entitlement: 12})

    assert {:ok, %{granted: 1}} = Leave.grant_entitlements(scope, 73, 2026)

    assert {:ok, [%{occurred_on: ~D[2026-04-01], leave_year: 2026}]} =
             Leave.entries(scope, 73, employee.id, 2026)

    assert {:error, :year_in_use} = Leave.put_rules(scope, 73, 1)
    assert {:ok, %{year_start_month: 4}} = Leave.put_rules(scope, 73, 4)
    assert {:error, :invalid_rules} = Leave.put_rules(scope, 73, 13)
  end

  test "opening and adjustment entries are idempotent by source and key", %{
    scope: scope,
    employee: employee
  } do
    type = annual_type(scope)

    entry = %{
      leave_type_id: type.id,
      entry_type: "opening",
      quantity: "3.5",
      occurred_on: ~D[2026-02-01],
      source: "operator",
      entry_key: "opening-1"
    }

    assert {:ok, saved} = Leave.record_entry(scope, 73, employee.id, entry)
    assert {:ok, ^saved} = Leave.record_entry(scope, 73, employee.id, entry)

    assert {:error, :entry_key_conflict} =
             Leave.record_entry(scope, 73, employee.id, %{entry | quantity: "4"})

    assert {:ok, _} =
             Leave.record_entry(scope, 73, employee.id, %{
               entry
               | entry_type: "adjustment",
                 quantity: "-1.25",
                 entry_key: "adjust-1"
             })

    assert {:ok, [%{opening: opening, adjustment: adjustment, balance: balance}]} =
             Leave.balances(scope, 73, employee.id, 2026)

    assert Decimal.equal?(opening, Decimal.new("3.5"))
    assert Decimal.equal?(adjustment, Decimal.new("-1.25"))
    assert Decimal.equal?(balance, Decimal.new("2.25"))

    for bad <- [
          %{entry | entry_type: "entitlement", entry_key: "x"},
          %{entry | entry_type: "taken", entry_key: "x"},
          %{entry | quantity: "0", entry_key: "x"},
          %{entry | quantity: "0.001", entry_key: "x"},
          %{entry | source: "policy", entry_key: "x"}
        ] do
      assert {:error, :invalid_entry} = Leave.record_entry(scope, 73, employee.id, bad)
    end
  end

  test "the ledger refuses edits and deletes", %{scope: scope, employee: employee} do
    type = annual_type(scope)

    {:ok, _} =
      Leave.record_entry(scope, 73, employee.id, %{
        leave_type_id: type.id,
        entry_type: "opening",
        quantity: 2,
        occurred_on: ~D[2026-02-01],
        source: "operator",
        entry_key: "opening-1"
      })

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.query!("UPDATE people_leave_ledger_entries SET quantity = 9")
    end
  end

  test "refuses sibling-company and cross-tenant access", %{
    scope: scope,
    other_scope: other,
    employee: employee
  } do
    type = annual_type(scope)

    assert {:error, :not_found} = Leave.list_types(other, 73)
    assert {:ok, []} = Leave.list_types(scope, 74)
    assert {:error, :not_found} = Leave.set_type_status(scope, 74, type.id, "archived")

    assert {:error, :not_found} =
             Leave.add_policy(scope, 74, type.id, %{
               effective_from: ~D[2026-01-01],
               entitlement: 1
             })

    assert {:error, :not_found} = Leave.balances(scope, 74, employee.id, 2026)
    assert {:error, :not_found} = Leave.balances(other, 73, employee.id, 2026)

    assert {:error, :not_found} =
             Leave.record_entry(scope, 74, employee.id, %{
               leave_type_id: type.id,
               entry_type: "opening",
               quantity: 1,
               occurred_on: ~D[2026-01-01],
               source: "operator",
               entry_key: "k"
             })

    {:ok, sibling_employee} =
      Employee.create_employee(scope, 74, %{employee_number: "E-2", full_name: "Employee Two"})

    assert {:error, :not_found} =
             Leave.record_entry(scope, 74, sibling_employee.id, %{
               leave_type_id: type.id,
               entry_type: "opening",
               quantity: 1,
               occurred_on: ~D[2026-01-01],
               source: "operator",
               entry_key: "k"
             })
  end

  test "contributions declare company-scoped settings and menu leaves" do
    contributions = Contributions.contributions()

    assert %{scopes: [:company], default: 1} =
             contributions.settings.definitions["people.leave.year_start_month"]

    assert %{scopes: [:company], default: [1, 2, 3, 4, 5]} =
             contributions.settings.definitions["people.leave.working_weekdays"]

    assert %{scopes: [:company], default: 30} =
             contributions.settings.definitions["people.leave.request_backdate_days"]

    assert Enum.map(contributions.menu, & &1.parent) ==
             ["people.my_work", "people.team", "people.settings"]
  end
end
