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
  }
]
