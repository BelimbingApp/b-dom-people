defmodule Bilimbi.People.Attendance.AllowanceRulesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Bilimbi.Base.Audit.TestFixtures, as: AuditFixtures
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.People.Attendance
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Attendance.{Contributions, TestFixtures}
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @capability "people.attendance.allowances.manage"

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

    AuthorizationFixtures.install_snapshot!("attendance-allowance-rules-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    AuditFixtures.create_audit_tables!()
    TestFixtures.create_attendance_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "second"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third"})
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    operator = AuthorizationFixtures.sign_in!(scope, 73, 91, [@capability])
    %{scope: scope, other_scope: other_scope, operator: operator}
  end

  test "allowance rules are written only under the allowances capability, checked now", %{
    scope: scope,
    operator: operator
  } do
    assert {:error, :unauthorized} =
             Attendance.create_allowance_rule(scope, 73, attrs("shift", ~D[2026-01-01], nil))

    assert {:ok, rule} =
             Attendance.create_allowance_rule(operator, 73, attrs("shift", ~D[2026-01-01], nil))

    :ok = AuthorizationFixtures.revoke!(scope, 73, 91, @capability)

    assert {:error, :unauthorized} =
             Attendance.end_allowance_rule(operator, 73, rule.id, ~D[2026-06-30])

    assert {:error, :unauthorized} = Attendance.retire_allowance_rule(operator, 73, rule.id)

    assert {:ok, [%{status: "active", effective_until: nil}]} =
             Attendance.list_allowance_rules(scope, 73)
  end

  test "catalog is company scoped and lists every version", %{
    scope: scope,
    other_scope: other,
    operator: operator
  } do
    assert {:ok, first} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("shift", ~D[2026-01-01], ~D[2026-06-30])
             )

    assert {:ok, second} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("shift", ~D[2026-07-01], nil, "9.2500")
             )

    assert {:ok, []} = Attendance.list_allowance_rules(scope, 74)
    assert {:error, :not_found} = Attendance.list_allowance_rules(other, 73)

    assert {:ok, [%{id: second_id, value: value}, %{id: first_id}]} =
             Attendance.list_allowance_rules(scope, 73)

    assert {first_id, second_id} == {first.id, second.id}
    assert Decimal.equal?(value, Decimal.new("9.25"))
  end

  test "a later version ends the open version the day before it starts, with an audit action",
       %{scope: scope, operator: operator} do
    assert {:ok, open} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("overtime", ~D[2026-01-01], nil)
             )

    assert {:ok, later} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("overtime", ~D[2026-04-01], nil)
             )

    assert {:ok, %{id: id, effective_until: ~D[2026-03-31]}} =
             Attendance.get_allowance_rule(scope, 73, open.id)

    assert id == open.id

    assert {:ok, %{effective_from: ~D[2026-04-01], effective_until: nil}} =
             Attendance.get_allowance_rule(scope, 73, later.id)

    assert [%{"rule_id" => rule_id, "effective_until" => "2026-03-31"}] =
             Repo.all(
               from(a in "base_audit_actions",
                 where: a.event == "people.attendance.allowance_rule_ended",
                 select: a.payload
               )
             )

    assert rule_id == open.id
  end

  test "rejects overlapping active periods and invalid values", %{operator: operator} do
    assert {:ok, _} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("overtime", ~D[2026-04-01], nil)
             )

    assert {:error, :effective_period_overlap} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("overtime", ~D[2026-01-01], ~D[2026-05-31])
             )

    assert {:error, :effective_period_overlap} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("overtime", ~D[2026-04-01], nil)
             )

    assert {:error, %Ecto.Changeset{} = changeset} =
             Attendance.create_allowance_rule(
               operator,
               73,
               Map.put(attrs("bad", ~D[2026-01-01], nil), :value, "0")
             )

    assert Keyword.has_key?(changeset.errors, :value)
  end

  test "retired versions do not block a new version of the code", %{operator: operator} do
    assert {:ok, retired} =
             Attendance.create_allowance_rule(
               operator,
               73,
               attrs("shift", ~D[2026-01-01], ~D[2026-12-31])
             )

    assert {:ok, _} = Attendance.retire_allowance_rule(operator, 73, retired.id)

    assert {:ok, _} =
             Attendance.create_allowance_rule(operator, 73, attrs("shift", ~D[2026-06-01], nil))
  end

  test "an active version can only be ended earlier and within its period", %{operator: operator} do
    assert {:ok, rule} =
             Attendance.create_allowance_rule(operator, 73, attrs("shift", ~D[2026-01-01], nil))

    assert {:error, %Ecto.Changeset{}} =
             Attendance.end_allowance_rule(operator, 73, rule.id, ~D[2025-12-31])

    assert {:ok, %{effective_until: ~D[2026-06-30]}} =
             Attendance.end_allowance_rule(operator, 73, rule.id, ~D[2026-06-30])

    assert {:error, :invalid_end_date} =
             Attendance.end_allowance_rule(operator, 73, rule.id, ~D[2026-09-30])

    assert {:ok, _} = Attendance.retire_allowance_rule(operator, 73, rule.id)

    assert {:error, :not_found} =
             Attendance.end_allowance_rule(operator, 73, rule.id, ~D[2026-03-31])
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
