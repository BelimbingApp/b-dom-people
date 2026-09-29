defmodule Bilimbi.People.ReferenceDataTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.People.ReferenceData

  setup do
    CompanyFixtures.create_company_identity_tables!()
    create_reference_tables!()
    CompanyFixtures.insert_tenant!()
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!()
    CompanyFixtures.insert_company!(%{id: 74, code: "second_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "third_company"})
    {:ok, first_scope} = Tenancy.scope(41)
    {:ok, second_scope} = Tenancy.scope(42)
    %{first_scope: first_scope, second_scope: second_scope}
  end

  test "requires an explicit company and refuses cross-company and cross-tenant aliases", %{
    first_scope: first,
    second_scope: second
  } do
    assert {:error, :company_not_found} = ReferenceData.list_entries(first, 75)
    assert {:error, :company_not_found} = ReferenceData.create_entry(first, 75, entry_attrs())
    assert {:error, :company_not_found} = ReferenceData.list_calendar_exceptions(second, 73)

    assert {:ok, entry} = ReferenceData.create_entry(first, 73, entry_attrs())
    assert {:ok, []} = ReferenceData.list_entries(first, 74)

    assert {:error, :entry_not_found} =
             ReferenceData.add_alias(first, 74, entry.id, %{label: "Other"})

    assert {:error, :entry_not_found} = ReferenceData.list_aliases(first, 74, entry.id)
  end

  test "stores operator-provided values without seeded defaults", %{first_scope: scope} do
    assert {:ok, []} = ReferenceData.list_entries(scope, 73)
    assert {:ok, []} = ReferenceData.list_calendar_exceptions(scope, 73)
    assert {:ok, entry} = ReferenceData.create_entry(scope, 73, entry_attrs())
    assert {:ok, _alias} = ReferenceData.add_alias(scope, 73, entry.id, %{label: "Alternate"})
    assert {:ok, [_alias]} = ReferenceData.list_aliases(scope, 73, entry.id)

    assert {:ok, _exception} =
             ReferenceData.create_calendar_exception(scope, 73, %{
               on_date: ~D[2026-10-01],
               label: "Operator exception"
             })

    assert {:ok, [_]} = ReferenceData.list_calendar_exceptions(scope, 73)
  end

  defp entry_attrs, do: %{kind: "category", code: "one", label: "First value"}

  defp create_reference_tables! do
    alias Bilimbi.Base.Repo
    alias Ecto.Adapters.SQL

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_reference_entries (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        kind varchar(80) NOT NULL, code varchar(100) NOT NULL,
        label varchar(200) NOT NULL, active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_reference_entries_company_kind_code_unique UNIQUE (company_id, kind, code)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_reference_aliases (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        entry_id bigint NOT NULL, label varchar(200) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_reference_aliases_company_label_unique UNIQUE (company_id, label)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE people_calendar_exceptions (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        on_date date NOT NULL, label varchar(200) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_calendar_exceptions_company_date_label_unique UNIQUE (company_id, on_date, label)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end
end
