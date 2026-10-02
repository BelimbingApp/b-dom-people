defmodule Bilimbi.People.Payroll.Web.SetupLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Payroll

  setup do
    UserFixtures.create_user_tables!()
    Bilimbi.People.Payroll.TestFixtures.create_tables!()
    Bilimbi.People.Attendance.TestFixtures.create_attendance_tables!()
    Bilimbi.People.Claims.TestFixtures.create_claim_tables!()
    Bilimbi.People.Leave.TestFixtures.create_leave_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, system} = Tenancy.scope(41)
    scope = Authentication.sign_in(system, 91, 73)
    %{scope: scope, system: system}
  end

  defp grant, do: grant_capabilities!(["people.payroll.view", "people.payroll.manage"])

  defp version(code),
    do: %{
      code: code,
      name: "Governed #{code}",
      effective_from: "2026-01-01",
      effective_to: "2026-12-31"
    }

  defp catalog(scope) do
    {:ok, :saved} = Payroll.put_settings(scope, 73, "Jurisdiction A", ["AAA", "BBB"])
    {:ok, classification} = Payroll.create_classification(scope, 73, version("class-a"))

    {:ok, item} =
      Payroll.create_item(
        scope,
        73,
        Map.merge(version("item-a"), %{
          classification_id: classification.id,
          currency: "AAA",
          amount: "0.123456"
        })
      )

    {:ok, period} =
      Payroll.create_period(scope, 73, %{
        code: "period-a",
        starts_on: "2026-01-01",
        ends_on: "2026-01-31",
        pay_on: "2026-02-01"
      })

    %{classification: classification, item: item, period: period}
  end

  test "route refuses anonymous and ungranted actors", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/payroll/setup")
    assert {:error, {_kind, _}} = conn |> log_in_as() |> live("/people/payroll/setup")
    {:ok, dashboard, _} = conn |> log_in_as() |> live("/dashboard")
    refute has_element?(dashboard, "a[href='/people/payroll/setup']")
    refute has_element?(dashboard, "a[href='/people/payroll/runs']")
  end

  test "pay-item mappings leaf opens the setup page at its mappings section", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/people/payroll/setup/mappings")
    grant_capabilities!("people.payroll.view")
    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup/mappings")

    assert has_element?(
             view,
             "a[href='/people/payroll/setup/mappings'][aria-current='page']",
             "Pay-item mappings"
           )

    refute has_element?(view, "a[href='/people/payroll/setup'][aria-current='page']")
    assert has_element?(view, "#payroll-mappings-section[tabindex='-1'][phx-mounted]")
    assert has_element?(view, "#mappings-empty")

    view |> form("#payroll-company", company_id: "73") |> render_change()
    assert_patch(view, "/people/payroll/setup/mappings?company_id=73")
    assert has_element?(view, "a[href='/people/payroll/setup/mappings'][aria-current='page']")
  end

  test "viewer sees empty states and forged writes are refused", %{conn: conn, scope: scope} do
    grant_capabilities!("people.payroll.view")
    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup")

    for selector <-
          ~w(#classifications-empty #items-empty #periods-empty #mappings-empty #runs-empty),
        do: assert(has_element?(view, selector))

    assert has_element?(
             view,
             "a[href='/people/payroll/setup'][aria-current='page']",
             "Payroll setup"
           )

    assert has_element?(view, "a[href='/people/payroll/setup/mappings']", "Pay-item mappings")
    refute has_element?(view, "a[href='/people/payroll/setup/mappings'][aria-current='page']")
    refute has_element?(view, "#payroll-mappings-section[phx-mounted]")
    assert has_element?(view, "a[href='/people/payroll/runs']", "Runs")
    refute has_element?(view, "#attendance-mapping-link")
    refute has_element?(view, "#classification-form")

    for event <-
          ~w(save_settings create_classification create_item create_period create_mapping create_run prepare_lock lock_run) do
      assert render_hook(view, event, %{}) =~ "You cannot change"
    end

    assert {:ok, %{classifications: []}} = Payroll.setup(scope, 73)
    assert {:error, :unauthorized} = Payroll.create_classification(scope, 73, version("denied"))
  end

  test "attendance mapping holders are pointed to the Attendance mappings page", %{conn: conn} do
    grant_capabilities!(["people.payroll.view", "people.payroll.attendance-mappings.manage"])
    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup")

    assert has_element?(
             view,
             ~s(#attendance-mapping-link a[href="/people/payroll/attendance-mappings?company_id=73"]),
             "Attendance mappings"
           )
  end

  test "operator creates governed settings and catalog through the page", %{
    conn: conn,
    scope: scope
  } do
    grant()
    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup")

    view
    |> form("#payroll-settings", country: "Jurisdiction A", currencies: "AAA")
    |> render_submit()

    view |> form("#classification-form", record: version("class-a")) |> render_submit()
    assert has_element?(view, "#payroll-classifications", "Classifications")
    assert {:ok, %{classifications: [classification]}} = Payroll.setup(scope, 73)

    view
    |> form("#item-form",
      record:
        Map.merge(version("item-a"), %{
          classification_id: classification.id,
          currency: "AAA",
          amount: "12.345678"
        })
    )
    |> render_submit()

    view
    |> form("#period-form",
      record: %{
        code: "period-a",
        starts_on: "2026-01-01",
        ends_on: "2026-01-31",
        pay_on: "2026-02-01"
      }
    )
    |> render_submit()

    assert {:ok, %{items: [item], periods: [period]}} = Payroll.setup(scope, 73)
    assert Decimal.equal?(item.amount, Decimal.new("12.345678"))
    view |> form("#run-form", period_id: period.id, currency: "AAA") |> render_submit()
    assert {:ok, %{runs: [run]}} = Payroll.setup(scope, 73)
    view |> element("#run-#{run.id} button") |> render_click()
    assert has_element?(view, "#payroll-lock-confirm")
    assert {:ok, %{runs: [%{locked_at: nil}]}} = Payroll.setup(scope, 73)
    view |> element("#payroll-lock-confirm-cancel") |> render_click()
    refute has_element?(view, "#payroll-lock-confirm")
    render_click(view, "lock_run", %{"id" => run.id})
    assert {:ok, %{runs: [%{locked_at: nil}]}} = Payroll.setup(scope, 73)
    view |> element("#run-#{run.id} button") |> render_click()
    view |> element("#payroll-lock-confirm-confirm") |> render_click()
    assert has_element?(view, "#run-#{run.id}", "Locked")
    refute has_element?(view, "#run-#{run.id} button")
  end

  test "tenant company and actor boundaries apply to every API", %{scope: scope, system: system} do
    grant()

    for company <- [74, 75] do
      assert {:error, _} = Payroll.setup(scope, company)
      assert {:error, _} = Payroll.put_settings(scope, company, "Other", ["AAA"])
      assert {:error, _} = Payroll.create_classification(scope, company, version("x"))
      assert {:error, _} = Payroll.create_period(scope, company, %{})
      assert {:error, _} = Payroll.create_mapping(scope, company, %{})
      assert {:error, _} = Payroll.create_run(scope, company, 1, "AAA")
      assert {:error, _} = Payroll.lock_run(scope, company, 1)
    end

    assert {:error, :unauthorized} = Payroll.create_classification(system, 73, version("x"))

    impersonated =
      Authentication.sign_in(system, 91, 73,
        impersonator_id: 92,
        impersonation_session_id: "test"
      )

    assert {:error, :unauthorized} = Payroll.create_classification(impersonated, 73, version("x"))
  end

  test "attendance mapping APIs require their own capability and a signed-in user", %{
    scope: scope,
    system: system
  } do
    grant()

    attrs = %{attendance_rule_code: "rule-a", item_id: 1, effective_from: "2026-01-01"}

    for actor_scope <- [scope, system] do
      assert {:error, :unauthorized} = Payroll.attendance_allowances(actor_scope, 73)

      assert {:error, :unauthorized} =
               Payroll.create_attendance_allowance_mapping(actor_scope, 73, attrs)
    end
  end

  test "attendance mappings are item-backed versions that runs freeze", %{scope: scope} do
    grant_capabilities!([
      "people.payroll.view",
      "people.payroll.manage",
      "people.payroll.attendance-mappings.manage"
    ])

    %{item: item, period: period} = catalog(scope)

    rules =
      for {code, currency, from} <- [
            {"rule-a", "AAA", ~D[2026-01-01]},
            {"rule-b", "BBB", ~D[2026-01-01]},
            {"rule-c", "AAA", ~D[2026-01-01]},
            {"rule-d", "AAA", ~D[2026-07-01]},
            {"rule-e", "AAA", ~D[2026-01-01]}
          ],
          into: %{} do
        {:ok, rule} =
          Bilimbi.People.Attendance.create_allowance_rule(scope, 73, %{
            code: code,
            name: "Rule #{code}",
            unit: "hour",
            value: "2",
            currency: currency,
            effective_from: from
          })

        {code, rule}
      end

    {:ok, _} = Bilimbi.People.Attendance.retire_allowance_rule(scope, 73, rules["rule-c"].id)

    attrs = %{
      attendance_rule_code: "rule-a",
      item_id: item.id,
      effective_from: "2026-01-01",
      effective_to: "2026-06-30"
    }

    assert {:ok, mapping} = Payroll.create_attendance_allowance_mapping(scope, 73, attrs)

    assert {:error, :overlapping_version} =
             Payroll.create_attendance_allowance_mapping(scope, 73, attrs)

    later = %{attrs | effective_from: "2026-07-01", effective_to: "2026-12-31"}

    for invalid <- [
          %{later | attendance_rule_code: "missing"},
          %{later | item_id: -1},
          %{later | effective_to: nil},
          %{later | attendance_rule_code: "rule-b"},
          %{later | attendance_rule_code: "rule-c"},
          %{attrs | attendance_rule_code: "rule-d"}
        ] do
      assert {:error, :invalid_mapping} =
               Payroll.create_attendance_allowance_mapping(scope, 73, invalid)
    end

    assert {:ok, %{sources: sources, items: [_], mappings: [%{id: id}]}} =
             Payroll.attendance_allowances(scope, 73, ~D[2026-01-15])

    assert Enum.map(sources, & &1.code) == ["rule-a", "rule-b", "rule-d", "rule-e"]

    assert id == mapping.id

    {:ok, run} = Payroll.create_run(scope, 73, period.id, "AAA")

    assert [%{"attendance_rule_code" => "rule-a", "item_id" => item_id}] =
             run.snapshot["attendance_mappings"]

    assert item_id == item.id

    assert for(
             %{"source_kind" => "attendance"} = unmapped <- run.snapshot["unmapped_sources"],
             do: unmapped
           ) == [
             %{"source_kind" => "attendance", "source_key" => "rule-e", "name" => "Rule rule-e"}
           ]
  end

  test "a run leaves out and reports an attendance mapping whose rule changed currency", %{
    scope: scope
  } do
    grant_capabilities!([
      "people.payroll.view",
      "people.payroll.manage",
      "people.payroll.attendance-mappings.manage"
    ])

    %{item: item, period: january} = catalog(scope)

    rule = fn currency, from ->
      {:ok, _} =
        Bilimbi.People.Attendance.create_allowance_rule(scope, 73, %{
          code: "shift",
          name: "Shift #{currency}",
          unit: "hour",
          value: "2",
          currency: currency,
          effective_from: from
        })
    end

    rule.("AAA", ~D[2026-01-01])

    {:ok, mapping} =
      Payroll.create_attendance_allowance_mapping(scope, 73, %{
        attendance_rule_code: "shift",
        item_id: item.id,
        effective_from: "2026-01-01",
        effective_to: "2026-12-31"
      })

    rule.("BBB", ~D[2026-02-01])

    {:ok, february} =
      Payroll.create_period(scope, 73, %{
        code: "period-b",
        starts_on: "2026-02-01",
        ends_on: "2026-02-28",
        pay_on: "2026-03-01"
      })

    {:ok, january_run} = Payroll.create_run(scope, 73, january.id, "AAA")
    assert [%{"id" => id}] = january_run.snapshot["attendance_mappings"]
    assert id == mapping.id

    {:ok, february_run} = Payroll.create_run(scope, 73, february.id, "AAA")
    assert february_run.snapshot["attendance_mappings"] == []

    assert %{
             "source_kind" => "attendance",
             "source_key" => "shift",
             "name" => "Shift BBB",
             "reason" => "currency mismatch"
           } in february_run.snapshot["unmapped_sources"]
  end

  test "versions reject overlaps, foreign classification, invalid money and dates", %{
    scope: scope
  } do
    grant()
    %{classification: classification} = catalog(scope)

    assert {:error, :overlapping_version} =
             Payroll.create_classification(scope, 73, version("class-a"))

    attrs =
      Map.merge(version("item-b"), %{
        classification_id: classification.id,
        currency: "AAA",
        amount: "1.0000001"
      })

    assert {:error, :invalid_item} = Payroll.create_item(scope, 73, attrs)
    assert {:error, _} = Payroll.create_item(scope, 73, %{attrs | amount: 0.1})

    assert {:error, :invalid_item} =
             Payroll.create_item(scope, 73, %{attrs | amount: "1", currency: "CCC"})

    assert {:error, :invalid_item} =
             Payroll.create_item(scope, 73, %{attrs | amount: "1", classification_id: -1})

    assert {:error, _} =
             Payroll.create_classification(scope, 73, %{
               code: "x",
               name: "X",
               effective_from: "bad",
               effective_to: "2026-01-01"
             })

    assert {:error, _} =
             Payroll.create_period(scope, 73, %{
               code: "bad",
               starts_on: "2026-01-01",
               ends_on: "2026-02-01",
               pay_on: "2026-01-01"
             })

    assert {:error, :invalid_record} =
             Payroll.create_period(scope, 73, %{
               code: "overlap",
               starts_on: "2026-01-15",
               ends_on: "2026-02-01",
               pay_on: "2026-02-02"
             })
  end

  test "Leave and Claims sources are validated and Attendance refuses mapping", %{scope: scope} do
    grant()
    %{item: item} = catalog(scope)

    {:ok, leave} =
      Bilimbi.People.Leave.create_type(scope, 73, %{
        code: "type-a",
        name: "Type A",
        unit: "day",
        paid: true
      })

    {:ok, category} =
      Bilimbi.People.Claims.create_category(scope, 73, %{code: "category-a", name: "Category A"})

    {:ok, claim} =
      Bilimbi.People.Claims.create_claim_type(scope, 73, %{
        code: "type-a",
        name: "Type A",
        category_id: category.id,
        receipt_requirement: "never"
      })

    assert {:ok, %{"attendance" => [], "leave" => [_], "claims" => [_]}} =
             Payroll.sources(scope, 73)

    for {kind, source} <- [{"leave", leave.id}, {"claims", claim.id}] do
      attrs = %{
        source_kind: kind,
        source_key: to_string(source),
        item_id: item.id,
        effective_from: "2026-01-01",
        effective_to: "2026-12-31"
      }

      assert {:ok, _} = Payroll.create_mapping(scope, 73, attrs)
      assert {:error, :overlapping_version} = Payroll.create_mapping(scope, 73, attrs)

      assert {:error, :invalid_mapping} =
               Payroll.create_mapping(scope, 73, %{attrs | source_key: "999999"})
    end

    assert {:error, _} =
             Payroll.create_mapping(scope, 73, %{
               source_kind: "attendance",
               source_key: "timezone",
               item_id: item.id,
               effective_from: "2026-01-01"
             })
  end

  test "run snapshot survives settings changes and a locked run stays locked", %{scope: scope} do
    grant()
    %{period: period} = catalog(scope)
    {:ok, run} = Payroll.create_run(scope, 73, period.id, "AAA")
    assert [%{"amount" => "0.123456"}] = run.snapshot["items"]
    assert {:error, :run_unavailable} = Payroll.create_run(scope, 73, period.id, "AAA")
    assert {:ok, locked} = Payroll.lock_run(scope, 73, run.id)
    assert locked.locked_by_actor_id == 91
    assert {:ok, :saved} = Payroll.put_settings(scope, 73, "Jurisdiction B", ["BBB"])

    assert {:ok, %{runs: [%{snapshot: snapshot, country: "Jurisdiction A", currency: "AAA"}]}} =
             Payroll.setup(scope, 73)

    assert snapshot == run.snapshot
    assert {:error, :locked} = Payroll.lock_run(scope, 73, run.id)
  end

  test "a source maps once per currency and runs report unmapped sources", %{
    conn: conn,
    scope: scope
  } do
    grant()
    %{classification: classification, item: item, period: period} = catalog(scope)

    {:ok, other} =
      Payroll.create_item(
        scope,
        73,
        Map.merge(version("item-b"), %{
          classification_id: classification.id,
          currency: "BBB",
          amount: "1"
        })
      )

    {:ok, mapped} =
      Bilimbi.People.Leave.create_type(scope, 73, %{
        code: "type-a",
        name: "Type A",
        unit: "day",
        paid: true
      })

    {:ok, unmapped} =
      Bilimbi.People.Leave.create_type(scope, 73, %{
        code: "type-b",
        name: "Type B",
        unit: "day",
        paid: false
      })

    attrs = %{
      source_kind: "leave",
      source_key: to_string(mapped.id),
      item_id: item.id,
      effective_from: "2026-01-01",
      effective_to: "2026-12-31"
    }

    assert {:ok, _} = Payroll.create_mapping(scope, 73, attrs)
    assert {:ok, _} = Payroll.create_mapping(scope, 73, %{attrs | item_id: other.id})

    assert {:error, :overlapping_version} =
             Payroll.create_mapping(scope, 73, %{attrs | item_id: other.id})

    runs =
      for {currency, item_id} <- [{"AAA", item.id}, {"BBB", other.id}] do
        {:ok, run} = Payroll.create_run(scope, 73, period.id, currency)
        assert [%{"item_id" => ^item_id}] = run.snapshot["mappings"]

        assert run.snapshot["unmapped_sources"] == [
                 %{
                   "source_kind" => "leave",
                   "source_key" => to_string(unmapped.id),
                   "name" => "Type B"
                 }
               ]

        run
      end

    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup")

    for run <- runs,
        do: assert(has_element?(view, "#run-unmapped-#{run.id}", "leave · Type B"))
  end

  test "unmapped report keeps inactive sources only with in-period activity", %{
    scope: scope,
    system: system
  } do
    grant()
    %{period: past} = catalog(scope)
    Bilimbi.People.ReferenceData.TestFixtures.create_reference_tables!()
    :ok = Bilimbi.Core.Employee.ensure_system_types()

    {:ok, employee} =
      Bilimbi.Core.Employee.create_employee(system, 73, %{
        employee_number: "E-1",
        full_name: "Employee One"
      })

    UserFixtures.insert_user!(%{
      id: 93,
      company_id: 73,
      employee_id: employee.id,
      email: "employee@example.com"
    })

    {:ok, period} =
      Payroll.create_period(scope, 73, %{
        code: "period-b",
        starts_on: "2099-03-01",
        ends_on: "2099-03-31",
        pay_on: "2099-04-01"
      })

    types =
      Map.new(~w(active used idle), fn code ->
        {:ok, type} =
          Bilimbi.People.Leave.create_type(scope, 73, %{
            code: code,
            name: "Leave #{code}",
            unit: "day",
            paid: true,
            balance_required: false
          })

        {code, type}
      end)

    assert {:ok, _} =
             Bilimbi.People.Leave.submit_request(
               system,
               73,
               %{type: :user, id: 93, company_id: 73},
               %{
                 leave_type_id: types["used"].id,
                 starts_on: ~D[2099-03-02],
                 ends_on: ~D[2099-03-02],
                 request_key: "payroll-activity"
               }
             )

    for code <- ~w(used idle),
        do: {:ok, _} = Bilimbi.People.Leave.set_type_status(scope, 73, types[code].id, "archived")

    {:ok, category} =
      Bilimbi.People.Claims.create_category(scope, 73, %{code: "category-a", name: "Category A"})

    {:ok, ["AAA"]} = Bilimbi.People.Claims.put_currencies(scope, 73, ["AAA"])

    claims =
      Map.new(~w(used idle), fn code ->
        {:ok, claim} =
          Bilimbi.People.Claims.create_claim_type(scope, 73, %{
            code: code,
            name: "Claim #{code}",
            category_id: category.id,
            receipt_requirement: "never"
          })

        {:ok, _} =
          Bilimbi.People.Claims.create_policy(scope, 73, %{
            claim_type_id: claim.id,
            effective_from: "2026-01-01",
            currency: "AAA"
          })

        {code, claim}
      end)

    assert {:ok, _} =
             Bilimbi.People.Claims.submit_request(system, 73, employee.id, 93, %{
               claim_type_id: claims["used"].id,
               incurred_on: "2026-01-15",
               amount: "40",
               currency: "AAA"
             })

    for {_, claim} <- claims,
        do: {:ok, _} = Bilimbi.People.Claims.set_claim_type_active(scope, 73, claim.id, false)

    for {run_period, names} <- [
          {period, ["Leave active", "Leave used"]},
          {past, ["Claim used", "Leave active"]}
        ] do
      {:ok, run} = Payroll.create_run(scope, 73, run_period.id, "AAA")
      assert Enum.sort(Enum.map(run.snapshot["unmapped_sources"], & &1["name"])) == names
    end
  end
end
