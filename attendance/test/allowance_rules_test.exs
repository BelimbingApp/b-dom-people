defmodule Bilimbi.People.Attendance.AllowanceRulesTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.People.Attendance
  alias Bilimbi.People.Attendance.{Contributions, TestFixtures}
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
        %{descriptor: %{id: "people/attendance"}, payload: Contributions.contributions().settings}
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "attendance-allowance-rules-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    SettingsFixtures.create_settings_table!()
    TestFixtures.create_attendance_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    %{scope: scope, other_scope: other_scope}
  end

  test "catalog is company scoped and Payroll sources resolve the effective version", %{
    scope: scope,
    other_scope: other
  } do
    assert {:ok, first} =
             Attendance.create_allowance_rule(
               scope,
               73,
               attrs("shift", ~D[2026-01-01], ~D[2026-06-30])
             )

    assert {:ok, second} =
             Attendance.create_allowance_rule(
               scope,
               73,
               attrs("shift", ~D[2026-07-01], nil, "9.2500")
             )

    assert {:ok, []} = Attendance.payroll_allowance_sources(scope, 74, ~D[2026-08-01])
    assert {:error, :not_found} = Attendance.list_allowance_rules(other, 73)

    assert {:ok, [%{id: id, code: "shift", value: value, currency: "USD"}]} =
             Attendance.payroll_allowance_sources(scope, 73, ~D[2026-03-01])

    assert id == first.id
    assert Decimal.equal?(value, Decimal.new("5.5"))

    assert {:ok, [%{id: id, value: value, effective_from: ~D[2026-07-01]}]} =
             Attendance.payroll_allowance_sources(scope, 73, ~D[2026-08-01])

    assert id == second.id
    assert Decimal.equal?(value, Decimal.new("9.25"))
  end

  test "rejects overlapping periods and invalid values", %{scope: scope} do
    assert {:ok, _} =
             Attendance.create_allowance_rule(scope, 73, attrs("overtime", ~D[2026-01-01], nil))

    assert {:error, :effective_period_overlap} =
             Attendance.create_allowance_rule(scope, 73, attrs("overtime", ~D[2026-04-01], nil))

    assert {:error, %Ecto.Changeset{} = changeset} =
             Attendance.create_allowance_rule(
               scope,
               73,
               Map.put(attrs("bad", ~D[2026-01-01], nil), :value, "0")
             )

    assert Keyword.has_key?(changeset.errors, :value)
  end

  defp attrs(code, from, until_date, value \\ "5.5000") do
    %{
      code: code,
      name: "#{code} allowance",
      unit: "hour",
      value: value,
      currency: "usd",
      effective_from: from,
      effective_until: until_date
    }
  end
end
