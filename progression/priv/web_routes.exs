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
    capability: {:any_of, ~w(people.progression.self.view people.performance.self.view)}
  }
]
