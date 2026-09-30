defmodule Bilimbi.People.Training.Web.TrainingLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.TestFixtures
  @courses_view "people.training.courses.view"
  @courses_manage "people.training.courses.manage"
  @sessions_view "people.training.sessions.view"
  @sessions_manage "people.training.sessions.manage"

  setup do
    UserFixtures.create_user_tables!()
    TestFixtures.create_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41, is_platform_operator: false})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  defp authenticated_scope(conn) do
    conn |> log_in_as() |> get("/people/training/courses") |> Map.fetch!(:assigns) |> Map.fetch!(:current_scope) |> Map.fetch!(:scope)
  end
  defp course(scope) do
    {:ok, record} = Training.create_course(scope, 73, %{code: "course-a", name: "Course A"})
    record
  end
  defp event(scope, course) do
    {:ok, record} = Training.create_event(scope, 73, %{course_id: course.id, name: "Event A", capacity: 10})
    record
  end
  defp session_attrs(event), do: %{event_id: event.id, name: "Session A", capacity: 5,
    time_zone: "America/New_York", starts_local: "2026-07-01T09:00", ends_local: "2026-07-01T10:00"}

  test "both routes require authentication and their view capability", %{conn: conn} do
    for path <- ["/people/training/courses", "/people/training/sessions"] do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
      assert {:error, _} = conn |> log_in_as() |> live(path)
    end
  end
  test "viewers see empty states and forged writes are refused", %{conn: conn} do
    grant_capabilities!([@courses_view, @sessions_view])
    conn = log_in_as(conn)
    {:ok, courses, _} = live(conn, "/people/training/courses")
    assert render(courses) =~ "No courses yet"
    refute has_element?(courses, "#course-form")
    assert render_hook(courses, "save_course_field", %{"id" => "1", "name" => "Forbidden"}) =~ "cannot change"
    assert render_hook(courses, "create_course", %{"course" => %{"code" => "x", "name" => "X"}}) =~ "cannot change"
    {:ok, sessions, _} = live(conn, "/people/training/sessions")
    assert render(sessions) =~ "No events yet"
    refute has_element?(sessions, "#training-entry-form")
    for event <- ~w(create_event create_session) do
      assert render_hook(sessions, event, %{"entry" => %{}}) =~ "cannot change"
    end
  end
  test "operator adds course, event and session and sees list and calendar", %{conn: conn} do
    grant_capabilities!([@courses_view, @courses_manage, @sessions_view, @sessions_manage])
    conn = log_in_as(conn)
    {:ok, catalog, _} = live(conn, "/people/training/courses")
    catalog |> element("button", "Add course") |> render_click()
    catalog |> form("#course-form", course: %{code: "course-a", name: "Course A"}) |> render_submit()
    assert has_element?(catalog, "#courses", "Course A")
    refute has_element?(catalog, "#courses-empty")
    {:ok, [course]} = Training.list_courses(authenticated_scope(conn), 73)
    render_hook(catalog, "save_course_field", %{"id" => to_string(course.id), "name" => "Course revised"})
    assert has_element?(catalog, "#courses", "Course revised")
    render_hook(catalog, "save_course_field", %{"id" => to_string(course.id), "description:#{course.id}" => "Description revised"})
    assert has_element?(catalog, "#courses", "Description revised")
    {:ok, schedule, _} = live(conn, "/people/training/sessions?date=2026-07-01")
    schedule |> element("button", "Add event") |> render_click()
    schedule |> form("#training-entry-form", entry: %{name: "Event A", capacity: "10"}) |> render_submit()
    assert has_element?(schedule, "#training-events", "Event A")
    schedule |> element("button", "Add session") |> render_click()
    schedule
    |> form("#training-entry-form", entry: %{name: "Session A", capacity: "11", time_zone: "America/New_York", starts_local: "2026-07-01T09:00", ends_local: "2026-07-01T10:00"})
    |> render_submit()
    assert render(schedule) =~ "Session capacity cannot exceed event capacity."

    schedule |> form("#training-entry-form", entry: %{name: "Session A", capacity: "5", time_zone: "America/New_York", starts_local: "2026-07-01T09:00", ends_local: "2026-07-01T10:00"}) |> render_submit()
    assert has_element?(schedule, "#training-sessions", "Session A")
    refute render(schedule) =~ "Session capacity cannot exceed event capacity."
    {:ok, calendar, _} = live(conn, "/people/training/sessions?date=2026-07-01&view=calendar")
    assert has_element?(calendar, "#training-calendar", "Session A")
  end
  test "API refuses system, same-tenant sibling company and other tenant", %{conn: conn} do
    grant_capabilities!([@courses_view, @courses_manage, @sessions_view, @sessions_manage])
    scope = authenticated_scope(conn)
    for company_id <- [74, 75] do
      assert {:error, :unauthorized} = Training.create_course(scope, company_id, %{code: "x", name: "X"})
      assert {:error, :unauthorized} = Training.list_events(scope, company_id)
      assert {:error, :unauthorized} = Training.calendar(scope, company_id, ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z])
    end
    {:ok, system} = Tenancy.scope(41)
    assert {:error, :unauthorized} = Training.create_course(system, 73, %{code: "x", name: "X"})
    assert {:error, :unauthorized} = Training.list_courses(system, 73)
  end
  test "scoped capacity, inactive course, duplicates and UTC overlap invariants", %{conn: conn} do
    grant_capabilities!([@courses_view, @courses_manage, @sessions_view, @sessions_manage])
    scope = authenticated_scope(conn)
    course = course(scope)
    event = event(scope, course)
    assert {:error, %Ecto.Changeset{}} = Training.create_course(scope, 73, %{code: "course-a", name: "Duplicate"})
    assert {:error, %Ecto.Changeset{}} = Training.create_event(scope, 73, %{course_id: course.id, name: "Empty", capacity: 0})
    assert {:error, %Ecto.Changeset{}} = Training.create_event(scope, 73, %{course_id: course.id, name: "Too large", capacity: 2_147_483_648})
    assert {:error, :not_found} = Training.update_course(scope, 73, 99_999_999_999_999_999_999, %{active: false})
    attrs = session_attrs(event)
    assert {:error, :capacity_exceeded} = Training.create_session(scope, 73, Map.put(attrs, :capacity, 11))
    assert {:error, %Ecto.Changeset{}} = Training.create_session(scope, 73, Map.put(attrs, :capacity, -1))
    assert {:error, :event_unavailable} = Training.create_session(scope, 73, Map.put(attrs, :event_id, 999999))
    assert {:error, :invalid_time_range} = Training.create_session(scope, 73, Map.put(attrs, :ends_local, "2026-07-01T08:00"))
    assert {:ok, %{starts_at: ~U[2026-07-01 13:00:00Z]}} = Training.create_session(scope, 73, attrs)
    assert {:ok, [_]} = Training.calendar(scope, 73, ~U[2026-07-01 13:30:00Z], ~U[2026-07-01 15:00:00Z])
    assert {:ok, []} = Training.calendar(scope, 73, ~U[2026-07-01 14:00:00Z], ~U[2026-07-01 15:00:00Z])
    assert {:error, :invalid_calendar_range} = Training.calendar(scope, 73, ~U[2026-07-01 14:00:00Z], ~U[2026-07-01 13:00:00Z])
    assert {:ok, _} = Training.update_course(scope, 73, course.id, %{active: false})
    assert {:error, :course_unavailable} = Training.create_event(scope, 73, %{course_id: course.id, name: "Inactive", capacity: 5})
    assert {:ok, [_]} = Training.list_events(scope, 73)
  end
  test "foreign parent records are refused and authorship cannot be supplied", %{conn: conn} do
    grant_capabilities!([@courses_view, @courses_manage, @sessions_view, @sessions_manage])
    scope = authenticated_scope(conn)
    UserFixtures.insert_user!(%{id: 92, company_id: 74, name: "Second operator", email: "second@example.test"})
    grant_capabilities!([@courses_view, @courses_manage, @sessions_view, @sessions_manage], company_id: 74, user_id: 92)
    other = conn |> log_in_as(session_user(%{"user_id" => 92, "company_id" => 74})) |> get("/people/training/courses")
    other_scope = other.assigns.current_scope.scope
    {:ok, other_course} = Training.create_course(other_scope, 74, %{code: "course-b", name: "Course B"})
    {:ok, other_event} = Training.create_event(other_scope, 74, %{course_id: other_course.id, name: "Event B", capacity: 10})
    assert {:error, :course_unavailable} = Training.create_event(scope, 73, %{course_id: other_course.id, name: "Wrong company", capacity: 10})
    assert {:error, :event_unavailable} = Training.create_session(scope, 73, session_attrs(other_event))
    assert {:error, :not_found} = Training.update_course(scope, 73, other_course.id, %{active: false})
    assert {:ok, %{actor_user_id: 91, impersonator_id: nil}} = Training.create_course(scope, 73, %{code: "owned", name: "Owned", actor_user_id: 92, impersonator_id: 92})
    {:ok, view, _} = conn |> log_in_as() |> live("/people/training/courses?company_id=74")
    refute has_element?(view, "#courses")
    assert render_hook(view, "create_course", %{"course" => %{}}) =~ "cannot change"
  end

  test "session-only viewers do not acquire catalog access", %{conn: conn} do
    grant_capabilities!(@sessions_view)
    {:ok, view, html} = conn |> log_in_as() |> live("/people/training/sessions")
    assert render(view) =~ "No events yet"
    refute html =~ ~s(href="/people/training/courses")
    assert {:error, _} = conn |> log_in_as() |> live("/people/training/courses")
  end

  test "revoking management refuses an already-open inline editor", %{conn: conn} do
    grant_capabilities!([@courses_view, @courses_manage])
    scope = authenticated_scope(conn)
    record = course(scope)
    {:ok, view, _} = conn |> log_in_as() |> live("/people/training/courses")
    {:ok, :stored} = Bilimbi.Base.Authz.put_principal_capability(scope, 73, :user, 91, @courses_manage, false)
    assert render_hook(view, "save_course_field", %{"id" => to_string(record.id), "name" => "Forbidden"}) =~ "cannot change"
    assert {:ok, [%{name: "Course A"}]} = Training.list_courses(scope, 73)
  end

end
