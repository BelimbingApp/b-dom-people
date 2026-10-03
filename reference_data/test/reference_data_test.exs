defmodule Bilimbi.People.ReferenceDataTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.ReferenceData
  alias Bilimbi.People.ReferenceData.Contributions
  alias Bilimbi.People.ReferenceData.TestFixtures, as: ReferenceFixtures
  alias Bilimbi.People.Workforce.AuthorizationFixtures

  @manage "people.references.manage"

  setup do
    AuthorizationFixtures.install_snapshot!("people-reference-data-test", %{
      authz: AuthorizationFixtures.authz_consumer!([Contributions])
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    # Creates the company identity tables too.
    UserFixtures.create_user_tables!()
    AuthzFixtures.create_authz_tables!()
    ReferenceFixtures.create_reference_tables!()
    CompanyFixtures.insert_tenant!()
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!()
    CompanyFixtures.insert_company!(%{id: 74, code: "second_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third_company"})
    {:ok, first_scope} = Tenancy.scope(41)
    {:ok, second_scope} = Tenancy.scope(42)

    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    UserFixtures.insert_user!(%{id: 92, company_id: 74, name: "Sibling", email: "s@example.com"})
    UserFixtures.insert_user!(%{id: 93, company_id: 73, name: "Viewer", email: "v@example.com"})
    operator = AuthorizationFixtures.sign_in!(first_scope, 73, 91, [@manage])
    sibling = AuthorizationFixtures.sign_in!(first_scope, 74, 92, [@manage])

    %{
      first_scope: first_scope,
      second_scope: second_scope,
      operator: operator,
      sibling: sibling
    }
  end

  test "requires an explicit company and refuses cross-company and cross-tenant aliases", %{
    first_scope: first,
    second_scope: second,
    operator: operator,
    sibling: sibling
  } do
    assert {:error, :company_not_found} = ReferenceData.list_entries(first, 75)
    assert {:error, :company_not_found} = ReferenceData.create_entry(operator, 75, entry_attrs())
    assert {:error, :company_not_found} = ReferenceData.list_calendar_exceptions(second, 73)

    assert {:ok, entry} = ReferenceData.create_entry(operator, 73, entry_attrs())
    assert {:ok, []} = ReferenceData.list_entries(first, 74)

    # The sibling company's operator may write there, but the entry lives in
    # company 73, so the alias is refused on the entry, not the grant.
    assert {:error, :entry_not_found} =
             ReferenceData.add_alias(sibling, 74, entry.id, %{label: "Other"})

    assert {:ok, []} = ReferenceData.list_aliases(first, 74)
    assert {:error, :company_not_found} = ReferenceData.list_aliases(second, 73)
  end

  test "writes need the manage grant for the target company now", %{
    first_scope: first,
    operator: operator,
    sibling: sibling
  } do
    # A system scope names nobody; a signed-in user without the grant and an
    # operator of a sibling company are out of reach.
    assert {:error, :unauthorized} = ReferenceData.create_entry(first, 73, entry_attrs())

    viewer = AuthorizationFixtures.sign_in(first, 93, 73)
    assert {:error, :unauthorized} = ReferenceData.create_entry(viewer, 73, entry_attrs())
    assert {:error, :unauthorized} = ReferenceData.create_entry(sibling, 73, entry_attrs())
    assert {:error, :unauthorized} = ReferenceData.create_entry(operator, 74, entry_attrs())

    assert {:ok, entry} = ReferenceData.create_entry(operator, 73, entry_attrs())

    # The grant is revoked while the operator's scope stays in hand: every
    # write refuses from the next call on, and nothing is persisted.
    :ok = AuthorizationFixtures.revoke!(first, 73, 91, @manage)

    assert {:error, :unauthorized} =
             ReferenceData.create_entry(operator, 73, %{entry_attrs() | code: "two"})

    assert {:error, :unauthorized} =
             ReferenceData.add_alias(operator, 73, entry.id, %{label: "Refused"})

    assert {:error, :unauthorized} =
             ReferenceData.create_calendar_exception(operator, 73, %{
               on_date: ~D[2026-10-01],
               label: "Refused"
             })

    assert {:ok, [%{id: id}]} = ReferenceData.list_entries(first, 73)
    assert id == entry.id
    assert {:ok, []} = ReferenceData.list_aliases(first, 73)
    assert {:ok, []} = ReferenceData.list_calendar_exceptions(first, 73)
  end

  test "stores operator-provided values without seeded defaults", %{
    first_scope: scope,
    operator: operator
  } do
    assert {:ok, []} = ReferenceData.list_entries(scope, 73)
    assert {:ok, []} = ReferenceData.list_calendar_exceptions(scope, 73)
    assert {:ok, entry} = ReferenceData.create_entry(operator, 73, entry_attrs())
    assert {:ok, _alias} = ReferenceData.add_alias(operator, 73, entry.id, %{label: "Alternate"})
    assert {:ok, [%{entry_id: entry_id}]} = ReferenceData.list_aliases(scope, 73)
    assert entry_id == entry.id

    assert {:ok, _exception} =
             ReferenceData.create_calendar_exception(operator, 73, %{
               on_date: ~D[2026-10-01],
               label: "Operator exception"
             })

    assert {:ok, [_]} = ReferenceData.list_calendar_exceptions(scope, 73)
  end

  test "allows an alias label once per kind within a company", %{
    first_scope: scope,
    operator: operator
  } do
    assert {:ok, first} = ReferenceData.create_entry(operator, 73, entry_attrs())

    assert {:ok, same_kind} =
             ReferenceData.create_entry(operator, 73, %{entry_attrs() | code: "two"})

    assert {:ok, other_kind} =
             ReferenceData.create_entry(operator, 73, %{entry_attrs() | kind: "grade"})

    assert {:ok, _alias} = ReferenceData.add_alias(operator, 73, first.id, %{label: "Other"})

    assert {:error, %Ecto.Changeset{errors: [company_id: _]}} =
             ReferenceData.add_alias(operator, 73, same_kind.id, %{label: "Other"})

    assert {:ok, _alias} =
             ReferenceData.add_alias(operator, 73, other_kind.id, %{label: "Other"})

    assert {:ok, aliases} = ReferenceData.list_aliases(scope, 73)
    assert Enum.sort(Enum.map(aliases, & &1.entry_id)) == Enum.sort([first.id, other_kind.id])
  end

  defp entry_attrs, do: %{kind: "category", code: "one", label: "First value"}
end
