[
  %{
    path: "/people/skills",
    live: Bilimbi.People.Skills.Web.CatalogLive,
    session: :auth,
    capability: "people.skills.catalog.view"
  },
  %{
    path: "/people/skills/profiles/:id",
    live: Bilimbi.People.Skills.Web.ProfileLive,
    session: :auth,
    capability: "people.skills.catalog.view"
  },
  %{
    path: "/people/skills/assessments",
    live: Bilimbi.People.Skills.Web.AssessmentsLive,
    session: :auth,
    capability: "people.skills.assessments.view"
  },
  %{
    path: "/people/skills/actions",
    live: Bilimbi.People.Skills.Web.ActionsLive,
    session: :auth,
    capability: "people.skills.actions.view"
  },
  %{
    path: "/people/skills/my",
    live: Bilimbi.People.Skills.Web.MySkillsLive,
    session: :auth,
    capability: "people.skills.self.view"
  },
  %{
    path: "/people/skills/policy",
    live: Bilimbi.People.Skills.Web.PolicyLive,
    session: :auth,
    capability: "people.skills.policy.manage"
  }
]
