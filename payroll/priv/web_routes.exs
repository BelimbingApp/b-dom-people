[
  %{
    path: "/people/payroll/runs",
    live: Bilimbi.People.Payroll.Web.RunsLive,
    session: :auth,
    capability: "people.payroll.view"
  },
  %{
    path: "/people/payroll/documents/:id",
    controller: Bilimbi.People.Payroll.Web.DocumentController,
    action: :show,
    session: :auth,
    capability: "people.payroll.view"
  },
  %{
    path: "/people/payroll/setup",
    live: Bilimbi.People.Payroll.Web.SetupLive,
    session: :auth,
    capability: "people.payroll.view"
  },
  %{
    path: "/people/payroll/setup/mappings",
    live: Bilimbi.People.Payroll.Web.SetupLive,
    session: :auth,
    capability: "people.payroll.view"
  },
  %{
    path: "/people/payroll/attendance-mappings",
    live: Bilimbi.People.Payroll.Web.AttendanceMappingsLive,
    session: :auth,
    capability: "people.payroll.attendance-mappings.manage"
  }
]
