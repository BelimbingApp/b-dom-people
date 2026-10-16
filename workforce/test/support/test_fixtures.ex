defmodule Bilimbi.People.Workforce.TestFixtures do
  @moduledoc false
  # Workforce reads resolve employment facts from People's own table, so any
  # test that reads employees through the workforce seam creates it first.

  alias Bilimbi.Base.Repo
  alias Bilimbi.Core.Employee
  alias Bilimbi.People.Workforce.EmploymentOwner
  alias Bilimbi.People.Workforce.EmploymentRecord
  alias Ecto.Adapters.SQL

  defmodule SeamCore do
    @moduledoc false
    # A Core that offers the employment-owner seam; the pinned Core does not.
    def register_employment_owner(owner), do: send(self(), {:registered, owner})
    def unregister_employment_owner(owner), do: send(self(), {:unregistered, owner})
  end

  def create_workforce_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_workforce_employments (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        legacy_employee_id bigint NOT NULL, person_id bigint NOT NULL,
        affiliation_id bigint NOT NULL, employee_number varchar(255) NOT NULL,
        employment_type varchar(255) NOT NULL, status varchar(255) NOT NULL,
        employment_start date, employment_end date, metadata jsonb,
        legacy_created_at timestamp(0), claimed_at timestamp(0) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_workforce_employment_exceptions (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        legacy_employee_id bigint NOT NULL, reason varchar(64) NOT NULL,
        detected_at timestamp(0) NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    for {table, column} <- [
          {"people_workforce_employments", "legacy_employee_id"},
          {"people_workforce_employments", "affiliation_id"},
          {"people_workforce_employment_exceptions", "legacy_employee_id"}
        ] do
      SQL.query!(
        Repo,
        "CREATE UNIQUE INDEX IF NOT EXISTS #{table}_#{column}_index ON #{table} (#{column})",
        []
      )
    end

    :ok
  end

  @doc """
  Holds the employee's employment in People with the given facts, differing
  from Core's, and registers People as the employment owner for the test.
  """
  def hold_in_people!(scope, %{id: employee_id} = employee, facts) do
    {:ok, identity} = Employee.person_identity(scope, employee_id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(
      struct!(
        EmploymentRecord,
        Keyword.merge(
          [
            tenant_id: Bilimbi.Base.Tenancy.Scope.tenant_id(scope),
            company_id: employee.company_id,
            legacy_employee_id: employee_id,
            person_id: identity.person_id,
            affiliation_id: identity.affiliation_id,
            employee_number: employee.employee_number,
            employment_type: employee.employee_type,
            status: employee.status,
            claimed_at: now
          ],
          facts
        )
      )
    )

    :ok = EmploymentOwner.register(SeamCore)
    ExUnit.Callbacks.on_exit(&EmploymentOwner.unregister/0)
  end
end
