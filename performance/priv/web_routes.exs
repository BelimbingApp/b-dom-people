[
  %{
    path: "/people/performance",
    live: Bilimbi.People.Performance.Web.ReviewsLive,
    session: :auth,
    capability: "people.performance.view"
  },
  %{
    path: "/people/performance/my",
    live: Bilimbi.People.Performance.Web.MyLive,
    session: :auth,
    capability: "people.performance.self.view"
  }
]
