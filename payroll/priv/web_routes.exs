[
  %{
    path: "/people/payroll/setup",
    live: Bilimbi.People.Payroll.Web.SetupLive,
    session: :auth,
    capability: "people.payroll.view"
  }
]
