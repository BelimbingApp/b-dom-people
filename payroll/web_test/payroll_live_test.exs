defmodule Bilimbi.People.Payroll.Web.SetupLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Repo, Tenancy}
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Payroll
  alias Ecto.Adapters.SQL

  setup do
    UserFixtures.create_user_tables!()
    Bilimbi.People.Payroll.TestFixtures.create_tables!()
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
  end

  test "viewer sees empty states and forged writes are refused", %{conn: conn, scope: scope} do
    grant_capabilities!("people.payroll.view")
    {:ok, view, _} = conn |> log_in_as() |> live("/people/payroll/setup")

    for selector <-
          ~w(#classifications-empty #items-empty #periods-empty #mappings-empty #runs-empty),
        do: assert(has_element?(view, selector))

    assert has_element?(view, "#attendance-mapping-unavailable", "not available yet")
    refute has_element?(view, "#classification-form")

    for event <-
          ~w(save_settings create_classification create_item create_period create_mapping create_run lock_run) do
      assert render_hook(view, event, %{}) =~ "You cannot change"
    end

    assert {:ok, %{classifications: []}} = Payroll.setup(scope, 73)
    assert {:error, :unauthorized} = Payroll.create_classification(scope, 73, version("denied"))
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

  test "run snapshot survives settings changes and database refuses changing a locked run", %{
    scope: scope
  } do
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

    for sql <- [
          "UPDATE people_payroll_runs SET locked_at = NULL, locked_by_actor_id = NULL WHERE id = $1",
          "UPDATE people_payroll_runs SET snapshot = '{}' WHERE id = $1",
          "DELETE FROM people_payroll_runs WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(Repo, sql, [run.id], mode: :savepoint)
    end
  end
end
