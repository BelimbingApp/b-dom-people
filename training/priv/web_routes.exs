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
  },
  %{
    path: "/people/training/records",
    live: Bilimbi.People.Training.Web.RecordsLive,
    session: :auth,
    capability: "people.training.records.view"
  },
  %{
    path: "/people/training/evidence/:company_id/:id",
    controller: Bilimbi.People.Training.Web.EvidenceController,
    action: :show,
    session: :auth,
    capability: "people.training.records.view"
  }
]
