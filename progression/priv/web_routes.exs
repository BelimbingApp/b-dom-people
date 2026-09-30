[
  %{
    path: "/people/progression",
    live: Bilimbi.People.Progression.Web.PolicyLive,
    session: :auth,
    capability: "people.progression.policy.view"
  },
  %{
    path: "/people/progression/my",
    live: Bilimbi.People.Progression.Web.MyLive,
    session: :auth,
    capability: "people.progression.self.view"
  }
]
