defmodule Bilimbi.People.ClaimsApprovalTest do
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
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Claims
  alias Bilimbi.People.Claims.Contributions
  alias Bilimbi.People.Claims.TestFixtures, as: ClaimFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions

  @operator_capabilities ~w(people.claims.manage people.claims.approve people.claims.reimburse)
  @employee_capabilities ~w(people.claims.submit people.claims.approve people.claims.reimburse)

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

    AuthorizationFixtures.install_snapshot!("people-claims-approval-test", %{
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

    {:ok, second} =
      Employee.create_employee(scope, 73, %{employee_number: "E-2", full_name: "Employee Two"})

    {:ok, sibling} =
      Employee.create_employee(scope, 74, %{employee_number: "E-9", full_name: "Employee Nine"})

    # Actor 91 claims as employee one; 92 is an approver with no employee
    # record; 93 is linked to employee two. The employee logins also hold the
    # decision grants, so separation of duties, not a missing grant, is what
    # refuses their own claims. Each is signed in as the authentication edge does.
    UserFixtures.insert_user!(%{id: 91, company_id: 73, employee_id: employee.id})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "approver@example.com"})

    UserFixtures.insert_user!(%{
      id: 93,
      company_id: 73,
      employee_id: second.id,
      email: "second@example.com"
    })

    %{
      scope: scope,
      other_scope: other_scope,
      approver: AuthorizationFixtures.sign_in!(scope, 73, 92, @operator_capabilities),
      one: AuthorizationFixtures.sign_in!(scope, 73, 91, @employee_capabilities),
      two: AuthorizationFixtures.sign_in!(scope, 73, 93, @employee_capabilities),
      employee: employee,
      second: second,
      sibling: sibling
    }
  end

  defp open!(%{approver: approver}, opts \\ []) do
    {:ok, _} = Claims.put_currencies(approver, 73, ["AAA", "BBB"])

    {:ok, category} =
      Claims.create_category(approver, 73, %{"code" => "travel", "name" => "Travel"})

    {:ok, claim_type} =
      Claims.create_claim_type(approver, 73, %{
        "category_id" => category.id,
        "code" => "fuel",
        "name" => "Fuel",
        "receipt_requirement" => "never",
        "eligibility" => Keyword.get(opts, :eligibility, "all_employees")
      })

    {:ok, _policy} =
      Claims.create_policy(
        approver,
        73,
        Map.merge(
          %{
            "claim_type_id" => claim_type.id,
            "effective_from" => "2026-01-01",
            "currency" => "AAA"
          },
          Keyword.get(opts, :policy, %{})
        )
      )

    claim_type
  end

  defp claim(claim_type, attrs \\ %{}) do
    Map.merge(
      %{
        "claim_type_id" => claim_type.id,
        "incurred_on" => "2026-03-10",
        "amount" => "40.00",
        "currency" => "AAA"
      },
      attrs
    )
  end

  # Each employee submits through its own login.
  defp submit!(ctx, employee, claim_type, attrs \\ %{}) do
    claimant = if employee.employee_number == "E-1", do: ctx.one, else: ctx.two
    {:ok, request} = Claims.submit_request(claimant, 73, claim(claim_type, attrs))
    request
  end

  describe "assignments" do
    test "an assigned-only type opens only for assigned employees while an assignment is in effect",
         %{scope: scope, employee: employee, second: second} = ctx do
      claim_type = open!(ctx, eligibility: "assigned_only")

      assert {:ok, [%{eligibility: "assigned_only"}]} = Claims.claim_types(scope, 73)

      assert {:ok, []} =
               Claims.open_claim_types(scope, 73, ~D[2026-03-10], employee_id: employee.id)

      assert {:ok, [_]} = Claims.open_claim_types(scope, 73, ~D[2026-03-10])

      assert {:error, :claim_type_not_assigned} =
               Claims.submit_request(ctx.one, 73, claim(claim_type))

      {:ok, assignment} =
        Claims.create_assignment(ctx.approver, 73, %{
          "code" => "field",
          "name" => "Field staff",
          "effective_from" => "2026-02-01"
        })

      assert {:ok, %{claim_type_ids: [claim_type.id], employee_ids: [employee.id]}} ==
               Claims.set_assignment_members(ctx.approver, 73, assignment.id, [claim_type.id], [
                 Integer.to_string(employee.id)
               ])

      assert {:ok, [%{id: id}]} =
               Claims.open_claim_types(scope, 73, ~D[2026-03-10], employee_id: employee.id)

      assert id == claim_type.id

      assert {:ok, []} =
               Claims.open_claim_types(scope, 73, ~D[2026-01-15], employee_id: employee.id)

      assert {:ok, []} =
               Claims.open_claim_types(scope, 73, ~D[2026-03-10], employee_id: second.id)

      assert {:error, :claim_type_not_assigned} =
               Claims.submit_request(ctx.two, 73, claim(claim_type))

      assert {:error, :claim_type_not_assigned} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"incurred_on" => "2026-01-20"})
               )

      assert {:ok, _} = Claims.submit_request(ctx.one, 73, claim(claim_type))

      assert {:ok, ended} = Claims.end_assignment(ctx.approver, 73, assignment.id, ~D[2026-03-31])
      assert ended.effective_to == ~D[2026-03-31]

      assert {:error, :already_ended} =
               Claims.end_assignment(ctx.approver, 73, assignment.id, ~D[2026-04-30])

      assert {:error, :claim_type_not_assigned} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"incurred_on" => "2026-04-02", "amount" => "41"})
               )

      assert {:ok, [listed]} = Claims.assignments(ctx.approver, 73)
      assert listed.claim_type_ids == [claim_type.id]
      assert listed.employee_ids == [employee.id]
    end

    test "members must belong to the company, and the company axis is enforced",
         %{
           scope: scope,
           other_scope: other_scope,
           employee: employee,
           sibling: sibling
         } = ctx do
      claim_type = open!(ctx)

      {:ok, assignment} =
        Claims.create_assignment(ctx.approver, 73, %{
          "code" => "a",
          "name" => "A",
          "effective_from" => "2026-01-01"
        })

      assert {:error, %Ecto.Changeset{}} =
               Claims.create_assignment(ctx.approver, 73, %{
                 "code" => "a",
                 "name" => "Again",
                 "effective_from" => "2026-01-01"
               })

      assert {:error, %Ecto.Changeset{}} =
               Claims.create_assignment(ctx.approver, 73, %{
                 "code" => "b",
                 "name" => "B",
                 "effective_from" => "2026-02-01",
                 "effective_to" => "2026-01-01"
               })

      assert {:error, :employee_not_found} =
               Claims.set_assignment_members(ctx.approver, 73, assignment.id, [claim_type.id], [
                 sibling.id
               ])

      assert {:ok, [listed]} = Claims.assignments(ctx.approver, 73)
      assert listed.claim_type_ids == []

      assert {:error, :employee_not_found} =
               Claims.set_assignment_members(ctx.approver, 73, assignment.id, [], ["x"])

      assert {:error, :claim_type_not_found} =
               Claims.set_assignment_members(
                 ctx.approver,
                 73,
                 assignment.id,
                 [claim_type.id + 99],
                 [
                   employee.id
                 ]
               )

      assert {:ok, [listed]} = Claims.assignments(ctx.approver, 73)
      assert listed.employee_ids == []

      assert {:error, :not_found} =
               Claims.set_assignment_members(ctx.approver, 73, assignment.id + 99, [], [
                 employee.id
               ])

      assert {:error, :not_found} = Claims.assignments(other_scope, 73)
      assert {:error, :unauthorized} = Claims.create_assignment(other_scope, 73, %{})

      assert {:error, :unauthorized} =
               Claims.set_assignment_members(other_scope, 73, assignment.id, [], [employee.id])

      assert {:ok, %{claim_type_ids: [], employee_ids: []}} =
               Claims.set_assignment_members(ctx.approver, 73, assignment.id, [], [])

      assert {:ok, [listed]} = Claims.assignments(ctx.approver, 73)
      assert listed.employee_ids == []
      assert {:ok, []} = Claims.assignments(ctx.approver, 74)
    end
  end

  describe "approval" do
    test "approve records the decision, history, and approved amount",
         %{
           scope: scope,
           employee: employee
         } = ctx do
      claim_type = open!(ctx)
      request = submit!(ctx, employee, claim_type)

      assert {:ok, [queued]} = Claims.claim_queue(ctx.approver, 73, "submitted")
      assert queued.id == request.id
      assert queued.employee_number == "E-1"
      assert queued.claim_type_code == "fuel"
      assert queued.category_name == "Travel"
      assert {:ok, []} = Claims.claim_queue(ctx.approver, 73, "approved")

      assert {:ok, approved} = Claims.approve_request(ctx.approver, 73, request.id, %{})
      assert approved.status == "approved"
      assert Decimal.equal?(approved.approved_amount, "40")
      assert approved.decided_by_actor_id == 92

      assert {:ok, [_, %{from_status: "submitted", to_status: "approved", actor_id: 92}]} =
               Claims.request_events(ctx.approver, 73, employee.id, request.id)

      assert {:error, :not_decidable} = Claims.approve_request(ctx.approver, 73, request.id, %{})

      assert {:error, :not_decidable} =
               Claims.reject_request(ctx.approver, 73, request.id, %{"decision_reason" => "no"})

      assert {:error, :not_withdrawable} =
               Claims.withdraw_request(ctx.one, 73, request.id)

      assert {:ok, [%{id: id}]} = Claims.claim_queue(ctx.approver, 73, "approved")
      assert id == request.id
    end

    test "a partial approval needs a reason and counts toward limits at the approved amount",
         %{
           scope: scope,
           employee: employee
         } = ctx do
      claim_type = open!(ctx, policy: %{"monthly_limit" => "100"})
      request = submit!(ctx, employee, claim_type, %{"amount" => "80"})

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Claims.approve_request(ctx.approver, 73, request.id, %{"approved_amount" => "50"})

      assert Keyword.has_key?(errors, :decision_reason)

      for bad <- ["81", "0", "-1", "1.005"] do
        assert {:error, %Ecto.Changeset{}} =
                 Claims.approve_request(ctx.approver, 73, request.id, %{
                   "approved_amount" => bad,
                   "decision_reason" => "why"
                 })
      end

      assert {:ok, approved} =
               Claims.approve_request(ctx.approver, 73, request.id, %{
                 "approved_amount" => "50",
                 "decision_reason" => "Only fuel is covered"
               })

      assert Decimal.equal?(approved.approved_amount, "50")
      assert approved.decision_reason == "Only fuel is covered"

      assert {:ok, _} = Claims.reimburse_request(ctx.two, 73, request.id, %{})

      assert {:ok,
              [
                _,
                %{to_status: "approved", reason: "Only fuel is covered"},
                %{to_status: "reimbursed", reason: nil}
              ]} = Claims.request_events(ctx.approver, 73, employee.id, request.id)

      # Only 50 of the month's 100 is still open: the approval released 30.
      assert {:error, :monthly_limit_exceeded} =
               Claims.submit_request(ctx.one, 73, claim(claim_type, %{"amount" => "80"}))

      assert {:ok, _} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"amount" => "50", "incurred_on" => "2026-03-11"})
               )

      assert {:error, :monthly_limit_exceeded} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"amount" => "0.01", "incurred_on" => "2026-03-12"})
               )
    end

    test "rejection needs a reason and releases limits and receipt references",
         %{
           scope: scope,
           employee: employee
         } = ctx do
      claim_type = open!(ctx, policy: %{"monthly_limit" => "100"})

      request =
        submit!(ctx, employee, claim_type, %{"amount" => "90", "receipt_number" => "R-1"})

      assert {:error, %Ecto.Changeset{}} =
               Claims.reject_request(ctx.approver, 73, request.id, %{})

      assert {:error, %Ecto.Changeset{}} =
               Claims.reject_request(ctx.approver, 73, request.id, %{"decision_reason" => "  "})

      assert {:error, :duplicate_receipt} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"amount" => "5", "receipt_number" => "r-1"})
               )

      assert {:ok, rejected} =
               Claims.reject_request(ctx.approver, 73, request.id, %{
                 "decision_reason" => "Not covered"
               })

      assert rejected.status == "rejected"
      assert is_nil(rejected.approved_amount)
      assert rejected.decision_reason == "Not covered"

      assert {:ok, [_, %{to_status: "rejected", reason: "Not covered"}]} =
               Claims.request_events(ctx.approver, 73, employee.id, request.id)

      assert {:error, :not_withdrawable} =
               Claims.withdraw_request(ctx.one, 73, request.id)

      assert {:ok, _} =
               Claims.submit_request(
                 ctx.one,
                 73,
                 claim(claim_type, %{"amount" => "90", "receipt_number" => "R-1"})
               )
    end

    test "an actor never decides its own or its linked employee's claim",
         %{
           scope: scope,
           employee: employee,
           second: second
         } = ctx do
      claim_type = open!(ctx)
      mine = submit!(ctx, employee, claim_type)

      assert {:error, :own_claim} = Claims.approve_request(ctx.one, 73, mine.id, %{})

      assert {:error, :own_claim} =
               Claims.reject_request(ctx.one, 73, mine.id, %{"decision_reason" => "x"})

      # Actor 91 submitted it; actor 93 is a different login linked to another
      # employee and may decide.
      assert {:ok, _} = Claims.approve_request(ctx.two, 73, mine.id, %{})
      assert {:error, :own_claim} = Claims.reimburse_request(ctx.one, 73, mine.id, %{})

      other = submit!(ctx, second, claim_type, %{"amount" => "7"})
      assert {:error, :own_claim} = Claims.approve_request(ctx.two, 73, other.id, %{})
      assert {:ok, _} = Claims.approve_request(ctx.one, 73, other.id, %{})
    end

    test "decisions are scoped to the tenant, company, and existing requests",
         %{
           scope: scope,
           other_scope: other_scope,
           employee: employee
         } = ctx do
      request = submit!(ctx, employee, open!(ctx))

      assert {:error, :unauthorized} = Claims.approve_request(other_scope, 73, request.id, %{})
      assert {:error, :unauthorized} = Claims.approve_request(ctx.approver, 74, request.id, %{})
      assert {:error, :not_found} = Claims.approve_request(ctx.approver, 73, request.id + 99, %{})
      assert {:error, :not_found} = Claims.approve_request(ctx.approver, 73, "x", %{})
      assert {:error, :unauthorized} = Claims.claim_queue(other_scope, 73, "submitted")
      # The approver's grants are in company 73 only.
      assert {:error, :unauthorized} = Claims.claim_queue(ctx.approver, 74, "submitted")
      assert {:ok, [%{id: id}]} = Claims.claim_queue(ctx.approver, 73, "submitted")
      assert id == request.id
    end

    test "each decision needs its own capability at the moment it runs",
         %{
           scope: scope,
           employee: employee
         } = ctx do
      claim_type = open!(ctx)
      request = submit!(ctx, employee, claim_type)
      approver = ctx.approver

      # Paying needs the reimbursement grant, deciding the approval grant;
      # one does not stand in for the other.
      :ok = AuthorizationFixtures.revoke!(scope, 73, 92, "people.claims.reimburse")
      assert {:ok, _} = Claims.approve_request(approver, 73, request.id, %{})
      assert {:error, :unauthorized} = Claims.reimburse_request(approver, 73, request.id, %{})
      assert {:error, :unauthorized} = Claims.create_handoff_batch(approver, 73, "AAA")
      assert {:ok, [{"AAA", 1, _}]} = Claims.handoff_waiting(approver, 73)
      assert {:ok, []} = Claims.handoff_batches(approver, 73)

      # The approval grant is revoked while the operator's page stays open:
      # the next decision and the next queue read are refused.
      second =
        submit!(ctx, employee, claim_type, %{"amount" => "5", "incurred_on" => "2026-03-11"})

      :ok = AuthorizationFixtures.revoke!(scope, 73, 92, "people.claims.approve")

      assert {:error, :unauthorized} =
               Claims.reject_request(approver, 73, second.id, %{"decision_reason" => "no"})

      assert {:error, :unauthorized} = Claims.claim_queue(approver, 73, "submitted")
      assert {:error, :unauthorized} = Claims.handoff_waiting(approver, 73)

      assert {:ok, [%{status: "submitted"}, %{status: "approved"}]} =
               Claims.employee_requests(ctx.two, 73, employee.id)
    end
  end

  describe "reimbursement and hand-off" do
    setup %{scope: scope, employee: employee, second: second} = ctx do
      claim_type = open!(ctx)

      {:ok, other_type} =
        Claims.create_claim_type(ctx.approver, 73, %{
          "category_id" => claim_type.category_id,
          "code" => "meals",
          "name" => "Meals, \"team\"",
          "receipt_requirement" => "never"
        })

      {:ok, _policy} =
        Claims.create_policy(ctx.approver, 73, %{
          "claim_type_id" => other_type.id,
          "effective_from" => "2026-01-01",
          "currency" => "BBB"
        })

      one = submit!(ctx, employee, claim_type, %{"amount" => "40"})

      two =
        submit!(ctx, second, other_type, %{
          "amount" => "12.50",
          "currency" => "BBB",
          "description" => "=HYPERLINK(\"http://x\")"
        })

      three = submit!(ctx, second, claim_type, %{"amount" => "10"})

      for request <- [one, two, three],
          do: {:ok, _} = Claims.approve_request(ctx.approver, 73, request.id, %{})

      %{claim_one: one, claim_two: two, claim_three: three}
    end

    test "a batch holds one currency, is recorded once, and exports current facts",
         %{
           scope: scope,
           claim_one: one,
           claim_two: two,
           claim_three: three
         } = ctx do
      assert {:error, :invalid_currency} = Claims.create_handoff_batch(ctx.approver, 73, "a1")
      assert {:error, :nothing_to_hand_off} = Claims.create_handoff_batch(ctx.approver, 73, "CCC")
      assert {:error, :not_found} = Claims.create_handoff_batch(ctx.approver, 74 + 99, "AAA")
      assert {:error, :not_found} = Claims.handoff_waiting(ctx.approver, 74 + 99)

      assert {:ok, [{"AAA", 2, aaa_total}, {"BBB", 1, bbb_total}]} =
               Claims.handoff_waiting(ctx.approver, 73)

      assert Decimal.equal?(aaa_total, "50")
      assert Decimal.equal?(bbb_total, "12.50")

      assert {:ok, batch} = Claims.create_handoff_batch(ctx.approver, 73, "aaa")
      assert batch.currency == "AAA"
      assert batch.request_count == 2
      assert Decimal.equal?(batch.total_amount, "50")
      assert batch.created_by_actor_id == 92

      assert {:error, :nothing_to_hand_off} = Claims.create_handoff_batch(ctx.approver, 73, "AAA")
      assert {:ok, [{"BBB", 1, _}]} = Claims.handoff_waiting(ctx.approver, 73)
      assert {:ok, [%{id: id}]} = Claims.handoff_batches(ctx.approver, 73)
      assert id == batch.id

      assert {:ok, %{filename: filename, content: csv}} =
               Claims.handoff_export(ctx.approver, 73, batch.id)

      assert filename == "claim-handoff-#{batch.id}.csv"
      assert [header, row_one, row_three, ""] = String.split(csv, "\r\n")
      assert header =~ "claim_id,employee_number,employee_name"

      assert row_one =~
               "#{batch.id},#{one.id},E-1,Employee One,Travel,fuel,Fuel,2026-03-10,AAA,40.00,40.00"

      assert row_three =~ ",#{three.id},E-2,Employee Two,"
      refute csv =~ "Meals"

      assert {:ok, second_batch} = Claims.create_handoff_batch(ctx.approver, 73, "BBB")
      assert {:ok, %{content: bbb}} = Claims.handoff_export(ctx.approver, 73, second_batch.id)
      assert bbb =~ "\"Meals, \"\"team\"\"\""
      assert bbb =~ "\"'=HYPERLINK(\"\"http://x\"\")\""
      assert bbb =~ ",#{two.id},"

      assert {:error, :unauthorized} = Claims.handoff_export(ctx.approver, 74, batch.id)
      assert {:error, :not_found} = Claims.handoff_export(ctx.approver, 73, batch.id + 99)
    end

    test "reimbursement records who paid and refuses anything but approved claims",
         %{
           scope: scope,
           employee: employee,
           claim_one: one
         } = ctx do
      assert {:error, :unauthorized} = Claims.reimburse_request(ctx.approver, 74, one.id, %{})

      assert {:error, %Ecto.Changeset{}} =
               Claims.reimburse_request(ctx.approver, 73, one.id, %{
                 "payment_reference" => String.duplicate("x", 101)
               })

      assert {:ok, paid} =
               Claims.reimburse_request(ctx.approver, 73, one.id, %{
                 "payment_reference" => "PAY-1"
               })

      assert paid.status == "reimbursed"
      assert paid.reimbursed_by_actor_id == 92
      assert paid.payment_reference == "PAY-1"
      assert Decimal.equal?(paid.approved_amount, "40")

      assert {:error, :not_decidable} = Claims.reimburse_request(ctx.approver, 73, one.id, %{})

      assert {:ok, [_, _, %{from_status: "approved", to_status: "reimbursed"}]} =
               Claims.request_events(ctx.approver, 73, employee.id, one.id)

      assert {:ok, [%{id: id}]} = Claims.claim_queue(ctx.approver, 73, "reimbursed")
      assert id == one.id
    end

    test "reimbursing a batch pays what is still approved and never the actor's own",
         %{
           scope: scope,
           claim_one: one,
           claim_three: three
         } = ctx do
      {:ok, batch} = Claims.create_handoff_batch(ctx.approver, 73, "AAA")
      assert {:ok, _} = Claims.reimburse_request(ctx.approver, 73, one.id, %{})

      assert {:error, :own_claim} = Claims.reimburse_batch(ctx.two, 73, batch.id, %{})

      assert {:ok, [%{id: id, status: "reimbursed"}]} =
               Claims.reimburse_batch(ctx.approver, 73, batch.id, %{
                 "payment_reference" => "RUN-1"
               })

      assert id == three.id

      assert {:error, :nothing_to_reimburse} =
               Claims.reimburse_batch(ctx.approver, 73, batch.id, %{})

      assert {:error, :not_found} = Claims.reimburse_batch(ctx.approver, 73, batch.id + 99, %{})
      assert {:error, :unauthorized} = Claims.reimburse_batch(ctx.approver, 74, batch.id, %{})

      assert {:ok, %{content: csv}} = Claims.handoff_export(ctx.approver, 73, batch.id)
      assert csv =~ "reimbursed"
      assert csv =~ "RUN-1"
    end
  end
end
