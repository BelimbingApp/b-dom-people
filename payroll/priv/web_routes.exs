[
  %{
    path: "/people/payroll/setup",
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
