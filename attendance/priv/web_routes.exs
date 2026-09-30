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
  },
  %{
    path: "/people/attendance/rules/shifts",
    live: Bilimbi.People.Attendance.Web.ShiftsLive,
    session: :auth,
    capability: "people.attendance.rules.manage"
  },
  %{
    path: "/people/attendance/rules/locations",
    live: Bilimbi.People.Attendance.Web.LocationsLive,
    session: :auth,
    capability: "people.attendance.rules.manage"
  },
  %{
    path: "/people/attendance/rules/allowances",
    live: Bilimbi.People.Attendance.Web.AllowancesLive,
    session: :auth,
    capability: "people.attendance.allowances.manage"
  },
  %{
    path: "/people/attendance/rosters",
    live: Bilimbi.People.Attendance.Web.RostersLive,
    session: :auth,
    capability: "people.attendance.roster.manage"
  },
  %{
    path: "/people/attendance/approvals",
    live: Bilimbi.People.Attendance.Web.ApprovalsLive,
    session: :auth,
    capability: "people.attendance.adjustments.approve"
  }
]
