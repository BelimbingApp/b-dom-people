[
  %{
    path: "/people/leave/my",
    live: Bilimbi.People.Leave.Web.MyLive,
    session: :auth,
    capability: "people.leave.self.view"
  },
  # Not /people/leave/approvals: the pinned platform's cutover tests use that
  # legacy path as one with no Bilimbi route.
  %{
    path: "/people/leave/requests",
    live: Bilimbi.People.Leave.Web.ApprovalsLive,
    session: :auth,
    capability: "people.leave.requests.approve"
  },
  %{
    path: "/people/leave/policies",
    live: Bilimbi.People.Leave.Web.PoliciesLive,
    session: :auth,
    capability: "people.leave.policies.manage"
  }
]
