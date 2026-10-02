[
  %{
    path: "/people/references",
    live: Bilimbi.People.ReferenceData.Web.IndexLive,
    session: :auth,
    capability: "people.references.manage"
  },
  %{
    path: "/people/companies/:company_id/references",
    live: Bilimbi.People.ReferenceData.Web.IndexLive,
    session: :auth,
    capability: "people.references.manage"
  }
]
