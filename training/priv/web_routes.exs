[
  %{
    path: "/people/training/courses",
    live: Bilimbi.People.Training.Web.CoursesLive,
    session: :auth,
    capability: "people.training.courses.view"
  },
  %{
    path: "/people/training/sessions",
    live: Bilimbi.People.Training.Web.SessionsLive,
    session: :auth,
    capability: "people.training.sessions.view"
  }
]
