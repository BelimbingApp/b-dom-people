[
  %{path: "/people/training/records/team", live: Bilimbi.People.Training.Web.PassportLive, session: :auth, capability: "people.training.passport.team.view"},
  %{path: "/people/training/records/team/document/:company_id/:id", controller: Bilimbi.People.Training.Web.PassportController, action: :show, session: :auth, capability: "people.training.passport.team.view"},
  %{path: "/people/training/records/team/evidence/:company_id/:id", controller: Bilimbi.People.Training.Web.PassportController, action: :evidence, session: :auth, capability: "people.training.passport.team.view"},
  %{path: "/people/training/records/my", live: Bilimbi.People.Training.Web.PassportLive, session: :auth, capability: "people.training.passport.my.view"},
  %{path: "/people/training/records/my/document/:company_id/:id", controller: Bilimbi.People.Training.Web.PassportController, action: :show, session: :auth, capability: "people.training.passport.my.view"},
  %{path: "/people/training/records/my/evidence/:company_id/:id", controller: Bilimbi.People.Training.Web.PassportController, action: :evidence, session: :auth, capability: "people.training.passport.my.view"},
  %{path: "/people/training/insights", live: Bilimbi.People.Training.Web.InsightsLive, session: :auth, capability: "people.training.insights.view"},
  %{
    path: "/people/training/effectiveness",
    live: Bilimbi.People.Training.Web.EffectivenessLive,
    session: :auth,
    capability: "people.training.effectiveness.view"
  },
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
    capability: "people.training.records.workspace.view"
  },
  %{
    path: "/people/training/evidence/:company_id/:id",
    controller: Bilimbi.People.Training.Web.EvidenceController,
    action: :show,
    session: :auth,
    capability: "people.training.records.view"
  },
  %{
    path: "/people/training/my",
    live: Bilimbi.People.Training.Web.LearningLive,
    session: :auth,
    capability: "people.training.learning.view"
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
  }
]
