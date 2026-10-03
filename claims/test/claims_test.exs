defmodule Bilimbi.People.ClaimsTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.DateTime.Contributions, as: DateTimeContributions
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Claims
  alias Bilimbi.People.Claims.Contributions
  alias Bilimbi.People.Claims.TestFixtures, as: ClaimFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @submit "people.claims.submit"
  @operator_capabilities ~w(people.claims.manage people.claims.approve people.claims.reimburse)

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{descriptor: %{id: "people/claims"}, payload: Contributions.contributions().settings},
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{
          descriptor: %{id: "base/datetime"},
          payload: DateTimeContributions.contributions().settings
        }
      ])

    AuthorizationFixtures.install_snapshot!("people-claims-test", %{
      settings: settings,
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    SettingsFixtures.create_settings_table!()
    ClaimFixtures.create_claim_tables!()
    :ok = Employee.ensure_system_types()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "Tenant A"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Tenant B", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})

    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{employee_number: "E-1", full_name: "Employee One"})

    {:ok, sibling} =
      Employee.create_employee(scope, 74, %{employee_number: "E-2", full_name: "Employee Two"})

    # Actor 91 is the employee's own login; 92 is an operator with no
    # employee record. Both are signed in as the authentication edge does.
    UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "operator@example.com"})
    claimant = AuthorizationFixtures.sign_in!(scope, 73, 91, [@submit])
    manager = AuthorizationFixtures.sign_in!(scope, 73, 92, @operator_capabilities)

    %{
      scope: scope,
      other_scope: other_scope,
      claimant: claimant,
      manager: manager,
      employee: employee,
      sibling: sibling
    }
  end

  defp catalog!(manager, company_id, receipt_requirement \\ "never") do
    {:ok, category} =
      Claims.create_category(manager, company_id, %{"code" => "travel", "name" => "Travel"})

    {:ok, claim_type} =
      Claims.create_claim_type(manager, company_id, %{
        "category_id" => Integer.to_string(category.id),
        "code" => "fuel",
        "name" => "Fuel",
        "receipt_requirement" => receipt_requirement
      })

    %{category: category, claim_type: claim_type}
  end

  defp open!(manager, policy_attrs \\ %{}, receipt_requirement \\ "never") do
    {:ok, ["AAA", "BBB"]} = Claims.put_currencies(manager, 73, ["aaa", " BBB "])
    %{claim_type: claim_type} = catalog!(manager, 73, receipt_requirement)

    {:ok, policy} =
      Claims.create_policy(
        manager,
        73,
        Map.merge(
          %{
            "claim_type_id" => claim_type.id,
            "effective_from" => "2026-01-01",
            "currency" => "AAA"
          },
          policy_attrs
        )
      )

    %{claim_type: claim_type, policy: policy}
  end

  defp claim(claim_type, attrs \\ %{}) do
    Map.merge(
      %{
        "claim_type_id" => Integer.to_string(claim_type.id),
        "incurred_on" => "2026-03-10",
        "amount" => "40.00",
        "currency" => "AAA"
      },
      attrs
    )
  end

  test "claim currencies are per company, normalized, and empty by default", %{
    scope: scope,
    other_scope: other_scope,
    manager: manager
  } do
    assert {:ok, []} = Claims.currencies(scope, 73)
    assert {:ok, ["AAA", "BBB"]} = Claims.put_currencies(manager, 73, ["aaa", "BBB", "AAA"])
    assert {:ok, ["AAA", "BBB"]} = Claims.currencies(scope, 73)
    assert {:ok, []} = Claims.currencies(scope, 74)
    assert {:error, :invalid_currencies} = Claims.put_currencies(manager, 73, ["AA1"])
    assert {:error, :invalid_currencies} = Claims.put_currencies(manager, 73, "AAA")
    # A system scope names nobody to authorize; the setting is untouched.
    assert {:error, :unauthorized} = Claims.put_currencies(other_scope, 73, ["AAA"])
    assert {:error, :unauthorized} = Claims.put_currencies(scope, 73, ["CCC"])
    assert {:ok, ["AAA", "BBB"]} = Claims.currencies(scope, 73)
    assert {:error, :not_found} = Claims.currencies(scope, 75)
  end

  test "catalog records stay inside one company and tenant", %{
    scope: scope,
    other_scope: other_scope,
    manager: manager
  } do
    %{category: category, claim_type: claim_type} = catalog!(manager, 73)

    assert {:error, %Ecto.Changeset{}} =
             Claims.create_category(manager, 73, %{"code" => "travel", "name" => "Again"})

    assert {:ok, [%{id: id}]} = Claims.categories(scope, 73)
    assert id == category.id
    assert {:ok, []} = Claims.categories(scope, 74)

    # The operator's grant is in company 73 only, and a category must be
    # one of the company's own.
    assert {:error, :unauthorized} =
             Claims.create_claim_type(manager, 74, %{
               "category_id" => category.id,
               "code" => "fuel",
               "name" => "Fuel",
               "receipt_requirement" => "never"
             })

    assert {:error, :category_not_found} =
             Claims.create_claim_type(manager, 73, %{
               "category_id" => category.id + 99,
               "code" => "fuel",
               "name" => "Fuel",
               "receipt_requirement" => "never"
             })

    assert {:error, %Ecto.Changeset{}} =
             Claims.create_claim_type(manager, 73, %{
               "category_id" => category.id,
               "code" => "other",
               "name" => "Other",
               "receipt_requirement" => "sometimes"
             })

    assert {:error, :unauthorized} =
             Claims.set_claim_type_active(manager, 74, claim_type.id, false)

    assert {:error, :not_found} =
             Claims.set_claim_type_active(manager, 73, claim_type.id + 99, false)

    assert {:error, :not_found} = Claims.categories(other_scope, 73)

    assert {:ok, %{active: false}} =
             Claims.set_claim_type_active(manager, 73, claim_type.id, false)
  end

  test "policies use an allowed currency, never overlap, and end only before claims", %{
    scope: scope,
    employee: employee,
    manager: manager,
    claimant: claimant
  } do
    %{claim_type: claim_type, policy: policy} = open!(manager, %{"per_claim_limit" => "100"})

    base = %{"claim_type_id" => claim_type.id, "currency" => "BBB"}

    assert {:error, %Ecto.Changeset{} = changeset} =
             Claims.create_policy(
               manager,
               73,
               Map.merge(base, %{"effective_from" => "2027-01-01", "currency" => "CCC"})
             )

    assert {:currency, _} = hd(changeset.errors)

    assert {:error, :overlapping_policy} =
             Claims.create_policy(manager, 73, Map.put(base, "effective_from", "2027-01-01"))

    assert {:error, :unauthorized} =
             Claims.create_policy(manager, 74, Map.put(base, "effective_from", "2027-01-01"))

    assert {:error, :claim_type_not_found} =
             Claims.create_policy(
               manager,
               73,
               base
               |> Map.put("effective_from", "2027-01-01")
               |> Map.put("claim_type_id", claim_type.id + 99)
             )

    assert {:ok, _} = Claims.submit_request(claimant, 73, claim(claim_type))

    assert {:error, :requests_after_end} =
             Claims.end_policy(manager, 73, policy.id, "2026-02-28")

    assert {:error, %Ecto.Changeset{}} = Claims.end_policy(manager, 73, policy.id, "2025-12-31")

    assert {:ok, %{effective_to: ~D[2026-12-31]}} =
             Claims.end_policy(manager, 73, policy.id, "2026-12-31")

    assert {:error, :already_ended} = Claims.end_policy(manager, 73, policy.id, "2027-06-30")

    assert {:ok, next} =
             Claims.create_policy(manager, 73, Map.put(base, "effective_from", "2027-01-01"))

    assert next.currency == "BBB"
    assert {:ok, [_, _]} = Claims.policies(scope, 73)
  end

  test "a threshold receipt rule needs a threshold on its policy", %{
    scope: scope,
    manager: manager
  } do
    {:ok, _} = Claims.put_currencies(manager, 73, ["AAA"])
    %{claim_type: claim_type} = catalog!(manager, 73, "above_threshold")

    attrs = %{
      "claim_type_id" => claim_type.id,
      "effective_from" => "2026-01-01",
      "currency" => "AAA"
    }

    assert {:error, %Ecto.Changeset{}} = Claims.create_policy(manager, 73, attrs)

    assert {:ok, %{receipt_threshold: threshold}} =
             Claims.create_policy(manager, 73, Map.put(attrs, "receipt_threshold", "25"))

    assert Decimal.equal?(threshold, 25)
  end

  test "submission records the fact, currency, policy, and history", %{
    scope: scope,
    employee: employee,
    manager: manager,
    claimant: claimant
  } do
    %{claim_type: claim_type, policy: policy} = open!(manager)

    assert {:ok, [%{id: open_id, policy: %{currency: "AAA"}}]} =
             Claims.open_claim_types(scope, 73, ~D[2026-03-10])

    assert open_id == claim_type.id
    assert {:ok, []} = Claims.open_claim_types(scope, 73, ~D[2025-12-31])

    assert {:ok, request} =
             Claims.submit_request(
               claimant,
               73,
               claim(claim_type, %{"description" => " Site visit ", "receipt_number" => " r-1 "})
             )

    assert request.status == "submitted"
    assert request.currency == "AAA"
    assert request.claim_policy_id == policy.id
    assert request.receipt_number == "R-1"
    assert request.description == "Site visit"
    assert Decimal.equal?(request.amount, 40)

    assert {:ok, [%{from_status: nil, to_status: "submitted", actor_id: 91}]} =
             Claims.request_events(manager, 73, employee.id, request.id)

    assert {:ok, [%{id: listed}]} = Claims.employee_requests(manager, 73, employee.id)
    assert listed == request.id
  end

  test "submission refuses closed, unmatched, and out-of-scope claims", %{
    scope: scope,
    other_scope: other_scope,
    employee: employee,
    sibling: sibling,
    manager: manager,
    claimant: claimant
  } do
    %{claim_type: claim_type} = open!(manager, %{"effective_to" => "2026-06-30"})
    future = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

    refusals = [
      {claim(claim_type, %{"currency" => "BBB"}), :currency_not_allowed},
      {claim(claim_type, %{"incurred_on" => "2025-12-31"}), :no_effective_policy},
      {claim(claim_type, %{"incurred_on" => future}), :future_incurred_on},
      {claim(claim_type, %{"claim_type_id" => "999999"}), :claim_type_unavailable}
    ]

    for {attrs, reason} <- refusals do
      assert {:error, ^reason} = Claims.submit_request(claimant, 73, attrs)
    end

    assert {:error, %Ecto.Changeset{}} =
             Claims.submit_request(claimant, 73, claim(claim_type, %{"amount" => "0"}))

    assert {:error, %Ecto.Changeset{}} =
             Claims.submit_request(claimant, 73, claim(claim_type, %{"amount" => "1.005"}))

    # A login linked to a sibling company's employee is not a claimant here,
    # a system scope names nobody, and the operator holds no self-service grant.
    UserFixtures.insert_user!(%{
      id: 93,
      company_id: 73,
      employee_id: sibling.id,
      email: "sibling@example.com"
    })

    sibling_login = AuthorizationFixtures.sign_in!(scope, 73, 93, [@submit])
    assert {:error, :not_linked} = Claims.submit_request(sibling_login, 73, claim(claim_type))
    assert {:error, :unauthorized} = Claims.submit_request(other_scope, 73, claim(claim_type))
    assert {:error, :unauthorized} = Claims.submit_request(manager, 73, claim(claim_type))

    {:ok, _} = Claims.put_currencies(manager, 73, ["BBB"])

    assert {:error, :currency_not_allowed} =
             Claims.submit_request(claimant, 73, claim(claim_type))

    {:ok, _} = Claims.put_currencies(manager, 73, ["AAA"])
    {:ok, _} = Claims.set_claim_type_active(manager, 73, claim_type.id, false)

    assert {:error, :claim_type_unavailable} =
             Claims.submit_request(claimant, 73, claim(claim_type))

    {:ok, inactive} =
      Employee.create_employee(scope, 73, %{
        employee_number: "E-3",
        full_name: "Former Employee",
        status: "terminated"
      })

    {:ok, _} = Claims.set_claim_type_active(manager, 73, claim_type.id, true)

    # Relinked to an employee who is no longer working: the account's current
    # link decides, so nothing is submitted for either employee.
    assert {:ok, _} = User.update_user(scope, 73, 91, %{employee_id: inactive.id})
    assert {:error, :not_linked} = Claims.submit_request(claimant, 73, claim(claim_type))

    assert {:ok, []} = Claims.employee_requests(manager, 73, employee.id)
    assert {:ok, []} = Claims.employee_requests(manager, 73, inactive.id)
  end

  test "receipt rules and per-claim, monthly, and yearly limits refuse submissions", %{
    scope: scope,
    employee: employee,
    claimant: claimant,
    manager: manager
  } do
    %{claim_type: claim_type} =
      open!(
        manager,
        %{
          "per_claim_limit" => "100",
          "monthly_limit" => "150",
          "yearly_limit" => "200",
          "receipt_threshold" => "50"
        },
        "above_threshold"
      )

    submit = fn attrs ->
      Claims.submit_request(claimant, 73, claim(claim_type, attrs))
    end

    assert {:error, :receipt_required} = submit.(%{"amount" => "60"})

    assert {:error, :per_claim_limit_exceeded} =
             submit.(%{"amount" => "101", "receipt_number" => "a"})

    assert {:ok, _} = submit.(%{"amount" => "50"})

    assert {:ok, _} =
             submit.(%{"amount" => "100", "receipt_number" => "b", "incurred_on" => "2026-03-11"})

    assert {:error, :monthly_limit_exceeded} =
             submit.(%{"amount" => "0.01", "incurred_on" => "2026-03-12"})

    assert {:ok, april} = submit.(%{"amount" => "50", "incurred_on" => "2026-04-01"})

    assert {:error, :yearly_limit_exceeded} =
             submit.(%{"amount" => "0.01", "incurred_on" => "2026-05-01"})

    assert {:ok, _} = Claims.withdraw_request(claimant, 73, april.id)
    assert {:ok, _} = submit.(%{"amount" => "0.01", "incurred_on" => "2026-05-01"})
  end

  test "duplicates are refused, a same-shape claim needs confirmation, and withdrawal frees them",
       %{scope: scope, employee: employee, manager: manager, claimant: claimant} do
    %{claim_type: claim_type} = open!(manager)

    submit = fn attrs ->
      Claims.submit_request(claimant, 73, claim(claim_type, attrs))
    end

    assert {:ok, first} = submit.(%{"receipt_number" => "Inv 7"})

    assert {:error, :duplicate_receipt} =
             submit.(%{"receipt_number" => " inv   7 ", "amount" => "5"})

    assert {:error, :possible_duplicate} = submit.(%{})
    assert {:ok, confirmed} = submit.(%{"confirm_duplicate" => "true"})
    assert confirmed.duplicate_confirmed

    assert {:error, :unauthorized} = Claims.withdraw_request(claimant, 74, first.id)

    assert {:ok, %{status: "withdrawn"}} =
             Claims.withdraw_request(claimant, 73, first.id)

    assert {:error, :not_withdrawable} =
             Claims.withdraw_request(claimant, 73, first.id)

    assert {:ok, [_, %{from_status: "submitted", to_status: "withdrawn"}]} =
             Claims.request_events(manager, 73, employee.id, first.id)

    assert {:ok, again} = submit.(%{"receipt_number" => "INV 7", "amount" => "5"})
    refute again.duplicate_confirmed
  end

  test "a receipt reference is refused on another claim type and currency",
       %{scope: scope, employee: employee, manager: manager, claimant: claimant} do
    %{claim_type: fuel} = open!(manager)

    {:ok, meals} =
      Claims.create_claim_type(manager, 73, %{
        "category_id" => Integer.to_string(fuel.category_id),
        "code" => "meals",
        "name" => "Meals",
        "receipt_requirement" => "never"
      })

    {:ok, _policy} =
      Claims.create_policy(manager, 73, %{
        "claim_type_id" => meals.id,
        "effective_from" => "2026-01-01",
        "currency" => "BBB"
      })

    assert {:ok, first} =
             Claims.submit_request(claimant, 73, claim(fuel, %{"receipt_number" => "Inv 7"}))

    meals_claim = claim(meals, %{"receipt_number" => "INV 7", "currency" => "BBB"})

    assert {:error, :duplicate_receipt} =
             Claims.submit_request(claimant, 73, meals_claim)

    assert {:ok, _} = Claims.withdraw_request(claimant, 73, first.id)
    assert {:ok, _} = Claims.submit_request(claimant, 73, meals_claim)
  end

  test "only a login actor linked to a working employee is a self-service claimant", %{
    scope: scope,
    employee: employee,
    claimant: claimant,
    manager: manager
  } do
    assert {:ok, %{id: id, employee_number: "E-1"}} = Claims.self_service_employee(claimant, 73)
    assert id == employee.id
    assert {:ok, []} = Claims.self_requests(claimant, 73)
    assert {:ok, []} = Claims.self_open_claim_types(claimant, 73)

    # The grant is per company, and a system scope names nobody.
    assert {:error, :unauthorized} = Claims.self_service_employee(claimant, 74)
    assert {:error, :unauthorized} = Claims.self_service_employee(scope, 73)
    assert {:error, :unauthorized} = Claims.self_requests(scope, 73)

    # The operator holds no self-service grant; with one, it has no employee.
    assert {:error, :unauthorized} = Claims.self_service_employee(manager, 73)
    :ok = AuthorizationFixtures.grant!(scope, 73, 92, @submit)
    assert {:error, :not_linked} = Claims.self_service_employee(manager, 73)
    assert {:error, :not_linked} = Claims.self_requests(manager, 73)
  end

  test "self-service refuses a revoked grant and a removed or changed account link", %{
    scope: scope,
    employee: employee,
    claimant: claimant,
    manager: manager
  } do
    %{claim_type: claim_type} = open!(manager)
    assert {:ok, request} = Claims.submit_request(claimant, 73, claim(claim_type))

    # The grant is revoked after the page resolved the employee: the next
    # write and the next read are refused.
    :ok = AuthorizationFixtures.revoke!(scope, 73, 91, @submit)
    assert {:error, :unauthorized} = Claims.withdraw_request(claimant, 73, request.id)
    assert {:error, :unauthorized} = Claims.self_requests(claimant, 73)
    assert {:ok, [%{status: "submitted"}]} = Claims.employee_requests(manager, 73, employee.id)

    # The link is removed while the grant stays: no employee to act for.
    :ok = AuthorizationFixtures.grant!(scope, 73, 91, @submit)
    assert {:ok, _} = User.update_user(scope, 73, 91, %{employee_id: nil})
    assert {:error, :not_linked} = Claims.withdraw_request(claimant, 73, request.id)
    assert {:error, :not_linked} = Claims.self_service_employee(claimant, 73)
    assert {:ok, [%{status: "submitted"}]} = Claims.employee_requests(manager, 73, employee.id)

    # Relinked to another employee: the former employee's claim is out of reach.
    {:ok, other} =
      Employee.create_employee(scope, 73, %{employee_number: "E-4", full_name: "Employee Four"})

    assert {:ok, _} = User.update_user(scope, 73, 91, %{employee_id: other.id})
    assert {:error, :not_found} = Claims.withdraw_request(claimant, 73, request.id)
    assert {:ok, []} = Claims.self_requests(claimant, 73)
    assert {:ok, [%{status: "submitted"}]} = Claims.employee_requests(manager, 73, employee.id)

    # Linked back: the claim can be withdrawn by its employee's login again.
    assert {:ok, _} = User.update_user(scope, 73, 91, %{employee_id: employee.id})
    assert {:ok, %{status: "withdrawn"}} = Claims.withdraw_request(claimant, 73, request.id)
  end

  test "operator writes and private reads refuse a system scope and a revoked grant", %{
    scope: scope,
    employee: employee,
    manager: manager,
    claimant: claimant
  } do
    %{claim_type: claim_type} = open!(manager)

    assert {:error, :unauthorized} =
             Claims.create_category(scope, 73, %{"code" => "x", "name" => "Refused"})

    assert {:error, :unauthorized} = Claims.employee_requests(scope, 73, employee.id)
    assert {:error, :unauthorized} = Claims.assignable_employees(claimant, 73)

    for capability <- @operator_capabilities,
        do: :ok = AuthorizationFixtures.revoke!(scope, 73, 92, capability)

    assert {:error, :unauthorized} =
             Claims.create_category(manager, 73, %{"code" => "x", "name" => "Refused"})

    assert {:error, :unauthorized} =
             Claims.set_claim_type_active(manager, 73, claim_type.id, false)

    assert {:error, :unauthorized} = Claims.employee_requests(manager, 73, employee.id)
    assert {:error, :unauthorized} = Claims.assignable_employees(manager, 73)
    assert {:ok, [%{code: "travel"}]} = Claims.categories(scope, 73)
    assert {:ok, [%{active: true}]} = Claims.claim_types(scope, 73)
  end
end
