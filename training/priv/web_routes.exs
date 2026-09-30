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
  },
  %{
    path: "/people/training/my",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.requests.submit"
  },
  %{
    path: "/people/training/team",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.requests.recommend"
  },
  %{
    path: "/people/training/plans",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.plans.submit"
  },
  %{
    path: "/people/training/requests",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.requests.view"
  },
  %{
    path: "/people/training/plan-reviews",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.plans.view"
  },
  %{
    path: "/people/training/budgets",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.budgets.view"
