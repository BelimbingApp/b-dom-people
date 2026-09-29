[
  %{
    path: "/people/claims",
    live: Bilimbi.People.Claims.Web.MyClaimsLive,
    session: :auth,
    capability: "people.claims.submit"
  },
  %{
    path: "/people/claims/setup",
    live: Bilimbi.People.Claims.Web.SetupLive,
    session: :auth,
    capability: "people.claims.manage"
  }
]
