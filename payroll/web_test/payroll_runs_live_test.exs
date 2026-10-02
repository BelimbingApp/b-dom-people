defmodule Bilimbi.People.Payroll.Web.RunsLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Artifacts, Settings, Tenancy}
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: Companies
  alias Bilimbi.Core.User.TestFixtures, as: Users
  alias Bilimbi.People.{Payroll, Workforce}

  setup do
    Users.create_user_tables!()
    Bilimbi.People.Payroll.TestFixtures.create_tables!()
    Bilimbi.People.Attendance.TestFixtures.create_attendance_tables!()
    Bilimbi.People.Leave.TestFixtures.create_leave_tables!()
    Bilimbi.People.Claims.TestFixtures.create_claim_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Companies.insert_tenant!(%{id: 41, is_platform_operator: true})
    Companies.insert_tenant!(%{id: 42, is_platform_operator: false})
    Companies.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    Companies.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    Companies.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    Users.insert_user!(%{id: 91, company_id: 73})
    Users.insert_user!(%{id: 92, company_id: 73, email: "reviewer@example.test"})
    {:ok, system} = Tenancy.scope(41)
    scope = Authentication.sign_in(system, 91, 73)
    reviewer = Authentication.sign_in(system, 92, 73)
    :ok = Bilimbi.Core.Employee.ensure_system_types()

    {:ok, employee} =
      Bilimbi.Core.Employee.create_employee(system, 73, %{
        employee_number: "E-A",
        full_name: "Employee A"
      })

    {:ok, _} = Workforce.put_working_statuses(scope, 73, ["active"])

    grant_capabilities!([
      "people.payroll.view",
      "people.payroll.manage",
      "people.payroll.approve"
    ])

    grant_capabilities!(["people.payroll.view", "people.payroll.approve"], user_id: 92)
    %{scope: scope, reviewer: reviewer, system: system, employee: employee}
  end

  defp frozen(scope) do
    {:ok, _} = Payroll.put_settings(scope, 73, "Jurisdiction A", ["AAA"])
    dates = %{code: "class-a", name: "Classification A", effective_from: "2026-01-01"}
    {:ok, classification} = Payroll.create_classification(scope, 73, dates)

    {:ok, item} =
      Payroll.create_item(
        scope,
        73,
        %{dates | code: "item-a", name: "Pay item A"}
        |> Map.merge(%{classification_id: classification.id, currency: "AAA", amount: "0.123456"})
      )

    {:ok, period} =
      Payroll.create_period(scope, 73, %{
        code: "period-a",
        starts_on: "2026-01-01",
        ends_on: "2026-01-31",
        pay_on: "2026-02-01"
      })

    {:ok, run} = Payroll.create_run(scope, 73, period.id, "AAA")
    %{run: run, item: item}
  end

  defp input(employee, item, key \\ "source-a"),
    do: %{
      source_key: key,
      employee_id: employee.id,
      item_id: item.id,
      on_date: "2026-01-05",
      units: "0.000001",
      direction: "earning",
      evidence: "Governed evidence A"
    }

  test "authorized page shows empty states and forged writes cannot bypass view permission", c do
    grant_capabilities!("people.payroll.manage", user_id: 91)
    {:ok, system} = Tenancy.scope(41)

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        system,
        73,
        :user,
        91,
        "people.payroll.manage",
        false
      )

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        system,
        73,
        :user,
        91,
        "people.payroll.approve",
        false
      )

    {:ok, view, _} = c.conn |> log_in_as() |> live("/people/payroll/runs")
    assert has_element?(view, "#payroll-no-runs")

    for event <- ~w(intake calculate generate_report generate_payslip decide),
        do: assert(render_hook(view, event, %{}) =~ "You cannot")

    assert {:error, _} = live(c.conn, "/people/payroll/runs")
    {:ok, foreign, _} = c.conn |> log_in_as() |> live("/people/payroll/runs?company_id=74")
    assert has_element?(foreign, "#payroll-runs-unavailable")
  end

  test "exact intake replay, frozen calculation and independent final approval", c do
    %{run: run, item: item} = frozen(c.scope)
    attrs = input(c.employee, item)
    assert {:ok, first} = Payroll.intake(c.scope, 73, run.id, attrs)
    assert {:ok, ^first} = Payroll.intake(c.scope, 73, run.id, attrs)
    assert {:error, :replay_conflict} = Payroll.intake(c.scope, 73, run.id, %{attrs | units: "1"})
    assert {:error, :run_not_locked} = Payroll.calculate(c.scope, 73, run.id)
    assert {:ok, _} = Payroll.lock_run(c.scope, 73, run.id)
    assert {:ok, calculation} = Payroll.calculate(c.scope, 73, run.id)
    assert {:ok, ^calculation} = Payroll.calculate(c.scope, 73, run.id)
    assert [%{"amount" => "0.000000123456"}] = calculation.snapshot["result"]["lines"]

    assert calculation.snapshot["result"] ==
             Bilimbi.People.Payroll.Replay.calculate(
               calculation.snapshot["setup"],
               calculation.snapshot["contributions"]
             )

    assert {:error, :intake_unavailable} =
             Payroll.intake(c.scope, 73, run.id, input(c.employee, item, "late"))

    assert {:error, :not_decidable} =
             Payroll.decide_run(c.scope, 73, run.id, "approved", "Own work")

    assert {:ok, _} =
             Payroll.decide_run(
               c.reviewer,
               73,
               run.id,
               "approved",
               "Independent evidence checked"
             )

    assert {:error, :not_decidable} =
             Payroll.decide_run(c.reviewer, 73, run.id, "rejected", "Changed mind")

    assert {:ok, %{decision: %{created_by_actor_id: 92}}} =
             Payroll.run_output(c.scope, 73, run.id)
  end

  test "intake refuses floats, precision loss, foreign employee, date and pay item", c do
    %{run: run, item: item} = frozen(c.scope)
    attrs = input(c.employee, item)

    for patch <- [
          %{units: 0.1},
          %{units: "0.0000001"},
          %{units: "0"},
          %{units: "100000000000000"}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Payroll.intake(c.scope, 73, run.id, Map.merge(attrs, patch))
    end

    for patch <- [%{employee_id: -1}, %{item_id: -1}, %{on_date: "2026-02-01"}] do
      assert {:error, _} = Payroll.intake(c.scope, 73, run.id, Map.merge(attrs, patch))
    end

    for company <- [74, 75] do
      assert {:error, _} = Payroll.intake(c.scope, company, run.id, attrs)
      assert {:error, _} = Payroll.calculate(c.scope, company, run.id)
      assert {:error, _} = Payroll.run_output(c.scope, company, run.id)
      assert {:error, _} = Payroll.decide_run(c.reviewer, company, run.id, "approved", "Reason")
      assert {:error, _} = Payroll.generate_document(c.scope, company, run.id, "report")
    end

    assert {:error, :unauthorized} = Payroll.intake(c.system, 73, run.id, attrs)

    impersonated =
      Authentication.sign_in(c.system, 91, 73,
        impersonator_id: 92,
        impersonation_session_id: "test"
      )

    assert {:error, :unauthorized} = Payroll.calculate(impersonated, 73, run.id)
  end

  test "mapped Attendance allowances enter calculation using their frozen item", c do
    grant_capabilities!([
      "people.attendance.allowances.manage",
      "people.payroll.attendance-mappings.manage"
    ])

    %{run: old, item: item} = frozen(c.scope)

    {:ok, _} =
      Bilimbi.People.Attendance.create_allowance_rule(c.scope, 73, %{
        code: "allowance-a",
        name: "Allowance A",
        unit: "day",
        value: "0.123456",
        currency: "AAA",
        effective_from: "2026-01-01"
      })

    {:ok, _} =
      Payroll.create_attendance_allowance_mapping(c.scope, 73, %{
        attendance_rule_code: "allowance-a",
        item_id: item.id,
        effective_from: "2026-01-01"
      })

    {:ok, period} =
      Payroll.create_period(c.scope, 73, %{
        code: "period-b",
        starts_on: "2026-02-01",
        ends_on: "2026-02-28",
        pay_on: "2026-03-01"
      })

    {:ok, run} = Payroll.create_run(c.scope, 73, period.id, "AAA")

    attrs =
      input(c.employee, item)
      |> Map.merge(%{
        attendance_rule_code: "allowance-a",
        on_date: "2026-02-05",
        item_id: -1,
        direction: "deduction"
      })

    assert {:error, :allowance_not_mapped} =
             Payroll.intake_attendance_allowance(c.scope, 73, old.id, attrs)

    assert {:ok, %{item_id: id, direction: "earning"}} =
             Payroll.intake_attendance_allowance(c.scope, 73, run.id, attrs)

    assert id == item.id
    {:ok, _} = Payroll.lock_run(c.scope, 73, run.id)
    assert {:ok, %{snapshot: snapshot}} = Payroll.calculate(c.scope, 73, run.id)
    assert [%{"amount" => "0.000000123456"}] = snapshot["result"]["lines"]
  end

  test "run page accepts inputs and renders frozen results", c do
    %{run: run, item: item} = frozen(c.scope)
    {:ok, _} = Payroll.lock_run(c.scope, 73, run.id)

    {:ok, view, _} =
      c.conn |> log_in_as() |> live("/people/payroll/runs?company_id=73&run_id=#{run.id}")

    assert has_element?(view, "#no-contributions")

    view
    |> form("#contribution-form",
      input: input(c.employee, item) |> Map.put(:source_kind, "direct")
    )
    |> render_submit()

    assert has_element?(view, "li", "source-a")
    view |> element("button", "Calculate permanently") |> render_click()
    assert has_element?(view, "#payroll-result", "0.000000123456")
    refute has_element?(view, "#contribution-form")

    view
    |> form("#decision-form", decision: %{outcome: "approved", reason: "Self"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "not_decidable")
  end

  test "approved PDFs use Base Artifacts, private downloads, current access and deletion", c do
    root = Path.expand("tmp/payroll-documents-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 1)
    %{run: run, item: item} = frozen(c.scope)
    {:ok, _} = Payroll.intake(c.scope, 73, run.id, input(c.employee, item))
    {:ok, _} = Payroll.lock_run(c.scope, 73, run.id)
    {:ok, _} = Payroll.calculate(c.scope, 73, run.id)
    assert {:error, _} = Payroll.generate_document(c.scope, 73, run.id, "report")
    {:ok, _} = Payroll.decide_run(c.reviewer, 73, run.id, "approved", "Checked")

    assert {:error, :invalid_document} =
             Payroll.generate_document(c.scope, 73, run.id, "payslip", -1)

    assert {:ok, report} = Payroll.generate_document(c.scope, 73, run.id, "report")

    assert {:ok, payslip} =
             Payroll.generate_document(c.scope, 73, run.id, "payslip", c.employee.id)

    assert {:ok, %{bytes: <<"%PDF-", _::binary>>}} =
             Payroll.read_document(c.scope, 73, payslip.artifact_id)

    download =
      c.conn
      |> log_in_as()
      |> get("/people/payroll/documents/#{report.artifact_id}?company_id=73")

    assert response(download, 200) =~ "%PDF-"
    assert get_resp_header(download, "cache-control") == ["private, no-store"]
    assert get_resp_header(download, "x-content-type-options") == ["nosniff"]

    assert response(
             c.conn
             |> log_in_as()
             |> get("/people/payroll/documents/#{report.artifact_id}?company_id=74"),
             404
           )

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        c.system,
        73,
        :user,
        91,
        "people.payroll.view",
        false
      )

    assert {:error, _} = Payroll.read_document(c.scope, 73, report.artifact_id)
    grant_capabilities!("people.payroll.view")

    {:ok, :deleted} =
      Artifacts.delete(c.scope, 73, Bilimbi.People.Payroll.DocumentOwner, report.artifact_id)

    assert {:error, :not_found} = Payroll.read_document(c.scope, 73, report.artifact_id)
  end
end
