defmodule Bilimbi.People.Training.Web.ParticipationLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Repo, Settings, Tenancy, Authz}
  alias Bilimbi.Core.{Employee, Company, User}
  alias Bilimbi.People.Training
  alias Bilimbi.People.Training.{Participation, TestFixtures}

  @capabilities ~w(people.training.courses.view people.training.courses.manage people.training.sessions.manage people.training.records.view people.training.records.manage people.training.evidence.manage people.training.retention.manage admin.employee.create)
  setup %{conn: conn} do
    User.TestFixtures.create_user_tables!()
    TestFixtures.create_tables!()
    TestFixtures.create_participation_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Company.TestFixtures.insert_tenant!(%{id: 41, is_platform_operator: false})
    Company.TestFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    Company.TestFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    User.TestFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    grant_capabilities!(@capabilities)
    conn = log_in_as(conn)
    scope = get(conn, "/people/training/courses").assigns.current_scope.scope

    {:ok, _} =
      Employee.create_employee_type(scope, 73, %{
        code: "employee_type_a",
        label: "Employee type A"
      })

    {:ok, employee} =
      Employee.create_employee(scope, 73, %{
        employee_number: "employee-a",
        full_name: "Employee A",
        employee_type: "employee_type_a",
        status: "active"
      })

    {:ok, employee2} =
      Employee.create_employee(scope, 73, %{
        employee_number: "employee-b",
        full_name: "Employee B",
        employee_type: "employee_type_a",
        status: "active"
      })

    {:ok, course} = Training.create_course(scope, 73, %{code: "course-a", name: "Course A"})

    {:ok, event} =
      Training.create_event(scope, 73, %{course_id: course.id, name: "Event A", capacity: 1})

    {:ok, session} =
      Training.create_session(scope, 73, %{
        event_id: event.id,
        name: "Session A",
        capacity: 1,
        time_zone: "Etc/UTC",
        starts_local: "2026-10-01T09:00",
        ends_local: "2026-10-01T10:00"
      })

    %{conn: conn, scope: scope, session: session, employee: employee, employee2: employee2}
  end

  defp attrs(c, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: c.session.id,
        employee_id: c.employee.id,
        status: "confirmed",
        reason: "Attendance confirmed",
        import_key: "record-a"
      },
      overrides
    )
  end

  test "exact imports replay; conflicts refuse; corrections preserve history and release capacity",
       c do
    assert {:ok, first} = Participation.record(c.scope, 73, attrs(c))
    assert {:ok, ^first} = Participation.record(c.scope, 73, attrs(c))

    assert {:error, :import_conflict} =
             Participation.record(c.scope, 73, attrs(c, %{status: "absent"}))

    assert {:error, :attendance_capacity_exceeded} =
             Participation.record(
               c.scope,
               73,
               attrs(c, %{employee_id: c.employee2.id, import_key: "record-b"})
             )

    assert {:ok, %{revision: 2, status: "absent", actor_user_id: 91}} =
             Participation.record(
               c.scope,
               73,
               attrs(c, %{
                 status: "absent",
                 reason: "Corrected attendance",
                 import_key: "correction-a",
                 actor_user_id: 92
               })
             )

    assert {:ok, _} =
             Participation.record(
               c.scope,
               73,
               attrs(c, %{employee_id: c.employee2.id, import_key: "record-b"})
             )

    assert {:ok, history} = Participation.history(c.scope, 73, c.session.id)
    assert length(history) == 3
    assert Enum.any?(history, &(&1.id == first.id and &1.status == "confirmed"))
  end

  test "scope and missing subjects fail closed", c do
    {:ok, system} = Tenancy.scope(41)
    assert {:error, :unauthorized} = Participation.record(system, 73, attrs(c))
    assert {:error, :unauthorized} = Participation.record(c.scope, 74, attrs(c))
    assert {:error, :not_found} = Participation.record(c.scope, 0, attrs(c))
    assert {:error, :not_found} = Participation.sessions(c.scope, 0)

    assert {:error, :session_unavailable} =
             Participation.record(c.scope, 73, attrs(c, %{session_id: 999_999}))

    assert {:error, :employee_unavailable} =
             Participation.record(c.scope, 73, attrs(c, %{employee_id: 999_999}))

    assert {:error, :invalid_record} =
             Participation.record(c.scope, 73, attrs(c, %{employee_id: "bad"}))

    assert {:ok, []} = Participation.history(c.scope, 73, c.session.id)
  end

  test "record page writes attendance, shows history, and rechecks revoked access", c do
    {:ok, view, html} = live(c.conn, "/people/training/records")
    assert html =~ "No attendance yet"

    view
    |> form("#participation-form",
      record: %{
        employee_id: c.employee.id,
        status: "confirmed",
        reason: "Attendance confirmed",
        import_key: "record-a"
      }
    )
    |> render_submit()

    assert has_element?(view, "#participation-history", "confirmed")
    refute has_element?(view, "#participation-history-empty")

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.scope,
        73,
        :user,
        91,
        "people.training.records.manage",
        false
      )

    assert render_hook(view, "record", %{
             "record" => %{
               employee_id: c.employee2.id,
               status: "confirmed",
               reason: "Forbidden",
               import_key: "record-b"
             }
           }) =~ "cannot"
  end

  test "viewer cannot forge any write event and routes require authentication", c do
    for capability <-
          ~w(people.training.records.manage people.training.evidence.manage people.training.retention.manage) do
      {:ok, :stored} = Authz.put_principal_capability(c.scope, 73, :user, 91, capability, false)
    end

    {:ok, view, _} = live(c.conn, "/people/training/records")
    refute has_element?(view, "#participation-form")

    for event <- ~w(record upload purge retry_purge),
        do: assert(render_hook(view, event, %{}) =~ "cannot change")

    assert {:error, _} = live(Phoenix.ConnTest.build_conn(), "/people/training/records")
  end

  test "evidence upload stays attached to its original attendance revision", c do
    root = Path.expand("tmp/training-upload-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, _} = Settings.put("artifacts.storage_root", root)
    assert {:ok, _} = Settings.put("artifacts.retention_days", 1)
    {:ok, fact} = Participation.record(c.scope, 73, attrs(c))
    {:ok, view, _} = live(c.conn, "/people/training/records")
    view |> element("button[phx-value-id='#{fact.id}']") |> render_click()

    upload =
      file_input(view, "#evidence-form", :evidence, [
        %{
          name: "evidence.pdf",
          content: "%PDF-1.4 evidence",
          type: "application/pdf"
        }
      ])

    assert render_upload(upload, "evidence.pdf") =~ "Add evidence"
    view |> element("#evidence-form") |> render_submit()
    assert has_element?(view, "#training-evidence a", "Download evidence PDF")
    refute has_element?(view, "#training-evidence-empty")
    assert {:ok, [document]} = Participation.evidence(c.scope, 73, fact.id)

    assert {:ok, correction} =
             Participation.record(
               c.scope,
               73,
               attrs(c, %{
                 status: "absent",
                 reason: "Attendance corrected",
                 import_key: "correction-a"
               })
             )

    assert {:ok, []} = Participation.evidence(c.scope, 73, correction.id)
    assert {:ok, [%{id: id}]} = Participation.evidence(c.scope, 73, fact.id)
    assert id == document.id

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.scope,
        73,
        :user,
        91,
        "people.training.retention.manage",
        false
      )

    assert {:error, _} = Participation.purge(c.scope, 73)
    assert {:error, _} = Participation.purge_holds(c.scope, 73)
    assert {:error, _} = Participation.retry_purge(c.scope, 73, document.artifact_id)

    assert {:ok, %{bytes: "%PDF-1.4 evidence"}} =
             Participation.read_evidence(c.scope, 73, document.artifact_id)
  end

  test "evidence access, expiry and retention use Base and preserve provenance", c do
    root = Path.expand("tmp/training-evidence-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, fact} = Participation.record(c.scope, 73, attrs(c))

    assert {:error, :retention_not_configured} =
             Participation.attach(c.scope, 73, fact.id, "%PDF-1.4 evidence")

    assert {:ok, _} = Settings.put("artifacts.storage_root", root)
    assert {:ok, _} = Settings.put("artifacts.retention_days", 1)
    assert {:error, :invalid_pdf} = Participation.attach(c.scope, 73, fact.id, "wrong")
    assert {:ok, evidence} = Participation.attach(c.scope, 73, fact.id, "%PDF-1.4 evidence")

    assert {:ok, %{bytes: "%PDF-1.4 evidence"}} =
             Participation.read_evidence(c.scope, 73, evidence.artifact_id)

    assert {:error, _} = Participation.read_evidence(c.scope, 74, evidence.artifact_id)
    download = get(c.conn, "/people/training/evidence/73/#{evidence.artifact_id}")
    assert download.status == 200
    assert get_resp_header(download, "cache-control") == ["private, no-store"]

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.scope,
        73,
        :user,
        91,
        "people.training.records.view",
        false
      )

    assert {:error, :unauthorized} =
             Participation.read_evidence(c.scope, 73, evidence.artifact_id)

    {:ok, :stored} =
      Authz.put_principal_capability(c.scope, 73, :user, 91, "people.training.records.view", true)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE base_artifacts SET expires_at = now() - interval '1 day' WHERE id = $1",
      [Ecto.UUID.dump!(evidence.artifact_id)]
    )

    assert {:error, :not_found} = Participation.read_evidence(c.scope, 73, evidence.artifact_id)
    assert {:ok, %{deleted: [id], errors: []}} = Participation.purge(c.scope, 73)
    assert id == evidence.artifact_id
    assert {:ok, [%{artifact_id: ^id}]} = Participation.evidence(c.scope, 73, fact.id)
    refute File.exists?(Path.join(root, id))
  end
end
