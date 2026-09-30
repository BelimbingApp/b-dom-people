[
  %{
    path: "/people/leave/my",
    live: Bilimbi.People.Leave.Web.MyLive,
    session: :auth,
    capability: "people.leave.self.view"
  },
  %{
    path: "/people/leave/policies",
    live: Bilimbi.People.Leave.Web.PoliciesLive,
    session: :auth,
    capability: "people.leave.policies.manage"
  }
]
