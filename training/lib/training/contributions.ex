defmodule Bilimbi.People.Training.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.training.currencies" => %{
            type: :array,
            scopes: [:company],
            default: [],
            label: "Learning currencies",
            help: "Currency codes accepted for this company's learning budgets and requests.",
            capability: "people.training.budgets.manage"
          }
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        verbs: ["recommend"],
        capabilities:
          ~w(people.training.courses.view people.training.courses.manage people.training.sessions.view people.training.sessions.manage people.training.requests.submit people.training.requests.recommend people.training.requests.review people.training.requests.approve people.training.requests.view people.training.plans.submit people.training.plans.approve people.training.plans.view people.training.budgets.view people.training.budgets.manage)
