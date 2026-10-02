defmodule Bilimbi.People.Training.Web.PassportLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Authz, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingScope
  alias Bilimbi.Core.{Company, Employee, User}
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.{Insights, Passport, Participation, TestFixtures}

  setup %{conn: conn} do
    User.TestFixtures.create_user_tables!()
    TestFixtures.migrate_evaluation_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Company.TestFixtures.insert_tenant!(%{id: 41, is_platform_operator: false})
    Company.TestFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    for {id, tenant} <- [{73, 41}, {74, 41}, {75, 42}] do
      Company.TestFixtures.insert_company!(%{id: id, tenant_id: tenant, name: "Company #{id}", code: "company-#{id}"})
    end
    {:ok, identity} = Tenancy.scope(41)
    {:ok, _} = Employee.create_employee_type(identity, 73, %{code: "type", label: "Employee type"})
    {:ok, manager} = Employee.create_employee(identity, 73, %{employee_number: "manager", full_name: "Employee A", employee_type: "type", status: "active"})
    {:ok, learner} = Employee.create_employee(identity, 73, %{employee_number: "learner", full_name: "Employee B", employee_type: "type", status: "active", supervisor_id: manager.id})
    {:ok, other} = Employee.create_employee(identity, 73, %{employee_number: "other", full_name: "Employee C", employee_type: "type", status: "active"})
    for {id, employee} <- [{91, nil}, {92, learner.id}, {93, manager.id}, {94, other.id}] do
      User.TestFixtures.insert_user!(%{id: id, company_id: 73, employee_id: employee, name: "Actor #{id}", email: "actor-#{id}@example.test"})
      grant_capabilities!(~w(people.training.courses.view people.training.learning.view people.training.records.workspace.view), user_id: id)
    end
    grant(91, ~w(courses.manage sessions.manage records.manage records.view evidence.manage retention.manage insights.view))
    grant(92, ~w(passport.my.view passport.generate requests.submit))
    grant(93, ~w(passport.my.view passport.team.view passport.generate requests.submit))
    grant(94, ~w(passport.my.view insights.view))
    scopes = Map.new(91..94, fn id -> {id, login(conn, id) |> get("/people/training/courses") |> Map.fetch!(:assigns) |> Map.fetch!(:current_scope) |> Map.fetch!(:scope)} end)
    {:ok, course} = Training.create_course(scopes[91], 73, %{code: "course", name: "Course A"})
    {:ok, event} = Training.create_event(scopes[91], 73, %{course_id: course.id, name: "Event A", capacity: 500})
    {:ok, session} = Training.create_session(scopes[91], 73, %{event_id: event.id, name: "Session A", capacity: 500, time_zone: "Etc/UTC", starts_local: "2026-10-01T09:00", ends_local: "2026-10-01T10:00"})
    {:ok, fact} = Participation.record(scopes[91], 73, %{session_id: session.id, employee_id: learner.id, status: "confirmed", reason: "Confirmed attendance", import_key: "fact-a"})
    %{conn: conn, scopes: scopes, learner: learner, manager: manager, other: other, fact: fact, session: session, course: course}
  end
  defp grant(id, caps), do: grant_capabilities!(Enum.map(caps, &("people.training." <> &1)), user_id: id)
  defp login(conn, id), do: log_in_as(conn, session_user(%{"user_id" => id}))
  defp storage do
    root = Path.expand("tmp/passport-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 1)
  end

  test "My and Team are linked employee reads; other employees, companies and system actors refuse", c do
    assert {:ok, %{page: %{entries: [row]}}} = Training.passport(c.scopes[92], 73, :self, c.learner.id)
    assert row.fact_id == c.fact.id
    assert {:error, :outside_team} = Training.passport(c.scopes[92], 73, :self, c.other.id)
    assert {:ok, _} = Training.passport(c.scopes[93], 73, :team, c.learner.id)
    assert {:error, :outside_team} = Training.passport(c.scopes[93], 73, :team, c.other.id)
    assert {:error, :outside_team} = Training.passport(c.scopes[93], 73, :team, c.manager.id)
    assert {:error, :unauthorized} = Training.passport(c.scopes[92], 74, :self, c.learner.id)
    assert {:error, :unauthorized} = Training.passport(c.scopes[92], 75, :self, c.learner.id)
    grant(91, ~w(passport.my.view))
    assert {:error, :employee_unavailable} = Passport.employees(c.scopes[91], 73, :self)
    {:ok, system} = Tenancy.scope(41)
    assert {:error, :unauthorized} = Training.passport(system, 73, :self, c.learner.id)
  end

  test "passport corrections select the latest fact and preserve evidence on the original revision", c do
    storage()
    {:ok, evidence} = Participation.attach(c.scopes[91], 73, c.fact.id, "%PDF-1.4 evidence")
    assert {:ok, %{page: %{entries: [%{evidence: [%{artifact_id: id}]}]}}} = Passport.read(c.scopes[92], 73, :self, c.learner.id)
    assert id == evidence.artifact_id
    assert {:ok, %{bytes: "%PDF-1.4 evidence"}} = Passport.read_evidence(c.scopes[92], 73, id)
    assert {:error, _} = Passport.read_evidence(c.scopes[94], 73, id)
    assert {:ok, %{revision: 2}} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.learner.id, status: "absent", reason: "Correction", import_key: "corrected"})
    assert {:ok, %{page: %{entries: [%{status: "absent", revision: 2, evidence: []}]}}} = Passport.read(c.scopes[92], 73, :self, c.learner.id)
    assert {:ok, %{bytes: "%PDF-1.4 evidence"}} = Passport.read_evidence(c.scopes[92], 73, id)
    download = get(login(c.conn, 92), "/people/training/records/my/evidence/73/#{id}")
    assert download.status == 200
    assert get_resp_header(download, "cache-control") == ["private, no-store"]
  end

  test "shared-renderer PDFs download privately and recheck revoked My and Team authority", c do
    storage()
    assert {:ok, document} = Training.generate_passport(c.scopes[92], 73, :self, c.learner.id)
    assert {:ok, %{bytes: bytes}} = Passport.download(c.scopes[92], 73, document.id)
    assert String.starts_with?(bytes, "%PDF-")
    assert bytes =~ "Training passport"
    assert bytes =~ "Course A"
    assert {:error, _} = Passport.download(c.scopes[94], 73, document.id)
    download = get(login(c.conn, 92), "/people/training/records/my/document/73/#{document.id}")
    assert download.status == 200
    assert get_resp_header(download, "x-content-type-options") == ["nosniff"]
    {:ok, team} = Training.generate_passport(c.scopes[93], 73, :team, c.learner.id)
    {:ok, identity} = Tenancy.scope(41)
    {:ok, _} = Employee.remove_subordinate(identity, 73, c.manager.id, c.learner.id)
    assert {:error, _} = Passport.download(c.scopes[93], 73, team.id)
    {:ok, :stored} = Authz.put_principal_capability(c.scopes[91], 73, :user, 92, "people.training.passport.my.view", false)
    assert {:error, _} = Passport.download(c.scopes[92], 73, document.id)
  end

  test "generation is refused without generate authority and above the record bound", c do
    storage()
    assert {:error, :forbidden} = Training.generate_passport(c.scopes[94], 73, :self, c.other.id)
    assert {:error, :unauthorized} = Training.generate_passport(c.scopes[92], 73, :team, c.learner.id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    entries = for n <- 1..1000, do: %{tenant_id: 41, company_id: 73, event_id: c.session.event_id, name: "Session #{n}", capacity: 2, time_zone: "Etc/UTC", starts_at: ~U[2026-10-01 09:00:00Z], ends_at: ~U[2026-10-01 10:00:00Z], actor_user_id: 91, inserted_at: now, updated_at: now}
    {1000, sessions} = Repo.insert_all(Training.Session, entries, returning: [:id])
    facts = Enum.map(sessions, &%{tenant_id: 41, company_id: 73, session_id: &1.id, employee_id: c.learner.id, revision: 1, status: "confirmed", reason: "Confirmed", import_key: "bound-#{&1.id}", actor_user_id: 91, inserted_at: now, updated_at: now})
    Repo.insert_all(Training.ParticipationFact, facts)
    assert {:error, :passport_too_large} = Training.generate_passport(c.scopes[92], 73, :self, c.learner.id)
    assert Repo.aggregate("base_artifacts", :count) == 0
  end

  test "passport task links follow passport authority, including the actor's own company", c do
    grant_capabilities!(~w(admin.company.tenant-wide.manage people.training.learning.view people.training.records.workspace.view), user_id: 92, company_id: 73)
    {:ok, view, _} = live(login(c.conn, 92), "/people/training/my?company_id=73")
    assert has_element?(view, "nav a", "My passport & evidence")
    {:ok, view, _} = live(login(c.conn, 92), "/people/training/my?company_id=74")
    refute has_element?(view, "nav a", "My passport & evidence")
    {:ok, view, _} = live(login(c.conn, 92), "/people/training/records?company_id=74")
    refute has_element?(view, "nav a", "My passport")
  end

  test "passport pages have My/Team tasks, honest empty states and refuse forged generate events", c do
    {:ok, view, html} = live(login(c.conn, 92), "/people/training/records/my")
    assert html =~ "Course A"
    assert has_element?(view, "nav a", "My passport")
    refute has_element?(view, "nav a", "Team passports")
    {:ok, other, html} = live(login(c.conn, 94), "/people/training/records/my")
    assert html =~ "No training records yet"
    assert render_hook(other, "generate", %{}) =~ "cannot generate"
    {:ok, team, _} = live(login(c.conn, 93), "/people/training/records/team")
    assert has_element?(team, "#passport-records", "Course A")
    refute has_element?(team, "#passport-records-empty")
    {:ok, forged, html} = live(login(c.conn, 93), "/people/training/records/team?employee_id=#{c.other.id}")
    assert html =~ "not available"
    assert render_hook(forged, "generate", %{}) =~ "cannot generate"
    assert {:error, _} = live(Phoenix.ConnTest.build_conn(), "/people/training/records/my")
    assert {:error, _} = live(login(c.conn, 94), "/people/training/records/team")
  end

  test "passport-only learners and managers can use menu shells without company-wide attendance", c do
    {:ok, mine, _} = live(login(c.conn, 94), "/people/training/my")
    assert has_element?(mine, "nav a", "My passport & evidence")
    assert render(mine) =~ "Choose a learning task"
    refute has_element?(mine, "#learning-records")
    {:ok, team, _} = live(login(c.conn, 93), "/people/training/records")
    assert has_element?(team, "nav a", "Team passports")
    refute has_element?(team, "#participation-history")
    assert render(team) =~ "Company-wide attendance and evidence need separate"
    assert {:error, :unauthorized} = Participation.sessions(c.scopes[93], 73)
  end

  test "insights suppress small cohorts and counts; drills require record-view authority and enforce the date and row bounds", c do
    params = %{"from" => "2026-10-01", "until" => "2026-10-02", "perPage" => "99999"}
    {:ok, _} = Settings.put("people.training.evaluation.minimum_cohort", 2, SettingScope.company(73, 41))
    freeze_period!(~D[2026-10-01], ~D[2026-12-31])
    period = Map.put(params, "period", "2026-10-01")
    assert {:ok, %{entries: [%{suppressed: true, employees: nil, confirmed: nil}], page_size: 25}} = Insights.summary(c.scopes[94], 73, period)
    assert {:error, :unauthorized} = Insights.drill(c.scopes[94], 73, c.course.id, params)
    assert {:ok, %{entries: [row]}} = Insights.drill(c.scopes[91], 73, c.course.id, params)
    for id <- [nil, "invalid", "-1", "99999999999999999999999999999"] do
      assert {:error, :not_found} = Insights.drill(c.scopes[91], 73, id, params)
    end
    assert row.fact_id == c.fact.id
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.other.id, status: "confirmed", reason: "Confirmed", import_key: "fact-b"})
    assert {:ok, %{entries: [%{suppressed: false, employees: 2, confirmed: nil, absent: nil}]}} = Insights.summary(c.scopes[91], 73, params)
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.manager.id, status: "confirmed", reason: "Confirmed", import_key: "fact-c"})
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.learner.id, status: "absent", reason: "Correction", import_key: "fact-d"})
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.manager.id, status: "absent", reason: "Correction", import_key: "fact-e"})
    assert {:ok, %{entries: [%{employees: 3, confirmed: nil, absent: nil}]}} = Insights.summary(c.scopes[91], 73, params)
    {:ok, later} = Training.create_session(c.scopes[91], 73, %{event_id: c.session.event_id, name: "Session B", capacity: 500, time_zone: "Etc/UTC", starts_local: "2026-10-02T09:00", ends_local: "2026-10-02T10:00"})
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: later.id, employee_id: c.learner.id, status: "confirmed", reason: "Confirmed", import_key: "fact-f"})
    assert {:ok, %{entries: [%{suppressed: false, employees: 3, confirmed: 2, absent: 2}]}} = Insights.summary(c.scopes[91], 73, params)
    assert {:error, :unauthorized} = Insights.summary(c.scopes[91], 74, params)
    assert {:error, :invalid_insight_range} = Insights.summary(c.scopes[91], 73, %{params | "until" => "2028-10-01"})
    assert {:error, :invalid_insight_range} = Insights.window(%{"from" => "invalid", "until" => "2026-10-01"})
    assert {:error, :invalid_insight_range} = Insights.window(%{"from" => "2026-10-02", "until" => "2026-10-01"})
    {:ok, view, html} = live(login(c.conn, 94), "/people/training/insights")
    assert html =~ "Course A"
    assert has_element?(view, "#insights-period")
    refute has_element?(view, "#learning-insights-empty")
    refute has_element?(view, "#insights-from")
    refute has_element?(view, "#learning-insights a", "View attendance")
    {:ok, _, html} = live(login(c.conn, 94), "/people/training/insights?from=2026-10-01&until=2026-10-02&course_id=#{c.course.id}")
    assert html =~ "cannot do that"
  end

  test "aggregate-only insights read whole frozen periods, so overlapping windows cannot be differenced", c do
    {:ok, _} = Settings.put("people.training.evaluation.minimum_cohort", 2, SettingScope.company(73, 41))
    assert {:error, :report_period_unavailable} = Insights.summary(c.scopes[94], 73, %{"from" => "2026-10-01", "until" => "2026-10-01"})
    freeze_period!(~D[2026-10-01], ~D[2026-12-31])
    {:ok, other} = Training.create_session(c.scopes[91], 73, %{event_id: c.session.event_id, name: "Session B", capacity: 500, time_zone: "Etc/UTC", starts_local: "2026-10-02T09:00", ends_local: "2026-10-02T10:00"})
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: c.session.id, employee_id: c.manager.id, status: "confirmed", reason: "Confirmed", import_key: "fact-b"})
    {:ok, _} = Participation.record(c.scopes[91], 73, %{session_id: other.id, employee_id: c.other.id, status: "absent", reason: "Absent", import_key: "fact-c"})
    assert {:ok, %{entries: [%{employees: 3, confirmed: nil, absent: nil}]}} = Insights.summary(c.scopes[94], 73, %{"period" => "2026-10-01"})
    for window <- [%{"from" => "2026-10-01", "until" => "2026-10-01"}, %{"from" => "2026-10-01", "until" => "2026-10-02"}] do
      assert {:ok, %{entries: [%{employees: 3}]}} = Insights.summary(c.scopes[94], 73, Map.put(window, "period", "2026-10-01"))
      assert {:error, :report_period_unavailable} = Insights.summary(c.scopes[94], 73, window)
    end
    for start <- ["2026-10-02", "2026-11-01", "invalid"] do
      assert {:error, :report_period_unavailable} = Insights.summary(c.scopes[94], 73, %{"period" => start})
    end
    assert {:ok, %{entries: [%{employees: 2}]}} = Insights.summary(c.scopes[91], 73, %{"from" => "2026-10-01", "until" => "2026-10-01"})
  end

  defp freeze_period!(first, last) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    Repo.insert_all(Training.EffectivenessSummary, [%{tenant_id: 41, company_id: 73, actor_user_id: 91, period_start: first, period_end: last, minimum_cohort: 2, status: "suppressed", groups: %{"items" => []}, inserted_at: now, updated_at: now}])
  end

  test "passport expiry and retention use the shared Training maintenance controls", c do
    storage()
    {:ok, document} = Training.generate_passport(c.scopes[92], 73, :self, c.learner.id)
    Ecto.Adapters.SQL.query!(Repo, "UPDATE base_artifacts SET expires_at = now() - interval '1 day' WHERE id = $1", [Ecto.UUID.dump!(document.id)])
    assert {:error, :not_found} = Passport.download(c.scopes[92], 73, document.id)
    assert {:ok, %{deleted: [id], errors: []}} = Participation.purge(c.scopes[91], 73)
    assert id == document.id
    assert {:error, :not_found} = Passport.download(c.scopes[92], 73, document.id)
  end

  test "SQL pagers bound records rather than reading an unbounded history", c do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    entries = for n <- 1..60, do: %{tenant_id: 41, company_id: 73, event_id: c.session.event_id, name: "Session #{n}", capacity: 2, time_zone: "Etc/UTC", starts_at: ~U[2026-10-01 09:00:00Z], ends_at: ~U[2026-10-01 10:00:00Z], actor_user_id: 91, inserted_at: now, updated_at: now}
    {60, sessions} = Repo.insert_all(Training.Session, entries, returning: [:id])
    facts = Enum.map(sessions, &%{tenant_id: 41, company_id: 73, session_id: &1.id, employee_id: c.learner.id, revision: 1, status: "confirmed", reason: "Confirmed", import_key: "bulk-#{&1.id}", actor_user_id: 91, inserted_at: now, updated_at: now})
    Repo.insert_all(Training.ParticipationFact, facts)
    assert {:ok, %{page: %{entries: rows, total_entries: 61, page: 2}}} = Passport.read(c.scopes[92], 73, :self, c.learner.id, %{"page" => "2"})
    assert length(rows) == 25
    assert {:ok, %{entries: drills, total_entries: 61, page: 3}} = Insights.drill(c.scopes[91], 73, c.course.id, %{"from" => "2026-10-01", "until" => "2026-10-01", "page" => "999999"})
    assert length(drills) == 11
  end
end
