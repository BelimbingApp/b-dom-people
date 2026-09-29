[
  %{
    path: "/people/attendance/my",
    live: Bilimbi.People.Attendance.Web.MyLive,
    session: :auth,
    capability: "people.attendance.self.view"
  },
  %{
    path: "/people/attendance/rules",
    live: Bilimbi.People.Attendance.Web.RulesLive,
    session: :auth,
    capability: "people.attendance.rules.manage"
  }
]
