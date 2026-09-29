[
  %{
    path: "/people/employees",
    live: Bilimbi.People.EmployeeWorkspace.Web.IndexLive,
    session: :auth,
    capability: "people.employees.view"
  },
  %{
    path: "/people/employees/:id",
    live: Bilimbi.People.EmployeeWorkspace.Web.ShowLive,
    session: :auth,
    capability: "people.employees.view"
  }
]
