defmodule Bilimbi.People.Skills.WorkflowFixtures do
  @moduledoc false
  # A small reporting line, users linked to it, and a published requirement
  # profile, for tests of the assessment, action and reminder workflows.
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Organisation.TestFixtures, as: OrganisationFixtures
  alias Bilimbi.People.Skills
  alias Bilimbi.People.Skills.TestFixtures

  @users %{manager: 101, lead: 102, one: 103, two: 104, hr: 105, outsider: 106, other: 107}

  @grants %{
    manager: ~w(people.skills.assessments.view people.skills.assessments.review
                people.skills.reassessments.submit people.skills.actions.approve
                people.skills.self.view),
    lead: ~w(people.skills.assessments.view people.skills.assessments.submit
             people.skills.reassessments.submit people.skills.self.view
             people.skills.actions.update),
    one: ~w(people.skills.self.view),
    two: ~w(people.skills.self.view),
    hr: ~w(people.skills.assessments.view people.skills.assessments.submit
           people.skills.assessments.approve people.skills.assessments.manage
           people.skills.reassessments.execute people.skills.reassessments.submit
           people.skills.actions.view people.skills.actions.manage
           people.skills.reminders.send people.skills.policy.manage
           people.skills.catalog.view people.skills.catalog.manage
           people.skills.profiles.publish people.skills.self.view),
    outsider: ~w(people.skills.assessments.view people.skills.assessments.submit
                 people.skills.assessments.review),
    other: ~w(people.skills.assessments.view people.skills.assessments.submit
              people.skills.assessments.manage)
  }

  def users, do: @users

  def seed! do
    UserFixtures.create_user_tables!()
    SettingsFixtures.create_settings_table!()
    OrganisationFixtures.create_position_tables!()
    TestFixtures.create_skill_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: true})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)

    manager = employee!(scope, 73, "M-1", "Manager Mona", nil)
    lead = employee!(scope, 73, "L-1", "Lead Lars", manager.id)
    one = employee!(scope, 73, "E-1", "Employee One", lead.id)
    two = employee!(scope, 73, "E-2", "Employee Two", lead.id)
    hr = employee!(scope, 73, "H-1", "Helper Hana", nil)
    outsider = employee!(scope, 73, "O-1", "Outsider Ola", nil)
    other = employee!(scope, 74, "X-1", "Other Company Otto", nil)

    people = %{
      manager: manager,
      lead: lead,
      one: one,
      two: two,
      hr: hr,
      outsider: outsider,
      other: other
    }

    for {role, employee} <- people do
      company = if role == :other, do: 74, else: 73

      UserFixtures.insert_user!(%{
        id: Map.fetch!(@users, role),
        company_id: company,
        employee_id: employee.id,
        name: employee.full_name,
        email: "#{role}@example.com"
      })
    end

    for {role, capabilities} <- @grants do
      company = if role == :other, do: 74, else: 73
      grant!(scope, role, company, capabilities)
    end

    ctx = %{scope: scope, people: people}
    Map.merge(ctx, catalog!(ctx))
  end

  def grant!(scope, role, company_id, capabilities) do
    for capability <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(
          scope,
          company_id,
          :user,
          Map.fetch!(@users, role),
          capability,
          true
        )
    end

    :ok
  end

  def actor(%{scope: scope}, role, company_id \\ 73),
    do: Authz.actor(:user, Map.fetch!(@users, role), scope, company_id)

  defp employee!(scope, company_id, number, name, supervisor_id) do
    {:ok, employee} =
      Employee.create_employee(scope, company_id, %{
        employee_number: number,
        full_name: name,
        status: "active",
        supervisor_id: supervisor_id
      })

    employee
  end

  # One category, a critical skill that reassesses every six months, a second
  # skill no profile requires, a three-level scale and a company-wide profile.
  defp catalog!(%{scope: scope} = ctx) do
    {:ok, category} = Skills.create_category(scope, 73, %{code: "technical", name: "Technical"})

    {:ok, welding} =
      Skills.create_skill(scope, 73, %{
        code: "welding",
        name: "Welding",
        definition: "Joins parts to the documented standard.",
        category_id: category.id,
        critical: true,
        reassessment_months: 6
      })

    {:ok, inspection} =
      Skills.create_skill(scope, 73, %{
        code: "inspection",
        name: "Inspection",
        definition: "Checks finished work.",
        category_id: category.id
      })

    {:ok, scale} = Skills.create_scale(scope, 73, %{code: "standard", name: "Standard"})

    for {name, level} <- Enum.with_index(~w(None Aware Competent Expert)) do
      {:ok, _} =
        Skills.put_scale_level(scope, 73, scale.id, %{
          level: level,
          name: name,
          anchor: "Observed #{name}",
          authority: "Works at #{name}"
        })
    end

    {:ok, scale} = Skills.publish_scale(scope, 73, scale.id)

    {:ok, profile} =
      Skills.create_profile(scope, 73, %{code: "base", name: "Base", scale_id: scale.id})

    {:ok, _} =
      Skills.put_item(scope, 73, profile.id, %{
        skill_id: welding.id,
        required_level: 2,
        criticality: "critical",
        weight_percent: "100",
        mandatory: true
      })

    {:ok, _} = Skills.add_selector(scope, 73, profile.id, :company)
    {:ok, profile} = Skills.publish_profile(actor(ctx, :hr), 73, profile.id, ~D[2020-01-01])
    %{welding: welding, inspection: inspection, scale: scale, profile: profile}
  end
end
