defmodule Bilimbi.People.Training.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @impl true
  def contributions do
    %{
      settings: %{
        definitions:
          Map.merge(policy_settings(), %{
            "people.training.currencies" => %{
              type: :array,
              scopes: [:company],
              default: [],
              label: "Learning currencies",
              help: "Currency codes accepted for this company's learning budgets and requests.",
              capability: "people.training.budgets.manage"
            }
          }),
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        verbs: ["recommend", "answer"],
        capabilities:
          ~w(people.training.courses.view people.training.courses.manage people.training.sessions.view people.training.sessions.manage people.training.records.view people.training.records.manage people.training.evidence.manage people.training.retention.manage people.training.requests.submit people.training.requests.recommend people.training.requests.review people.training.requests.approve people.training.requests.view people.training.plans.submit people.training.plans.approve people.training.plans.view people.training.budgets.view people.training.budgets.manage people.training.effectiveness.view people.training.evaluation.submit people.training.effectiveness.answer people.training.effectiveness.summary.view people.training.evaluation.policy.manage people.training.evaluation.reminders.manage)
      },
      menu: []
    }
  end

  # Rollout keeps Training hidden until all slices pass. This is the single
  # destination to contribute when that area is ready, never two role links.
  def effectiveness_menu do
    [
      %{
        id: "people.development.effectiveness",
        label: "Effectiveness",
        parent: "people.development",
        route: "/people/training/effectiveness",
        capability: "people.training.effectiveness.view",
        icon: "hero-chart-bar",
        order: 90
      }
    ]
  end

  defp policy_settings do
    Map.new(
      [
        {"evaluation_days", :integer, 0, 3650, "Evaluation due days",
         "Days after the session ends when employee evaluation is due."},
        {"reminder_days", :integer, 0, 3650, "Evaluation reminder lead",
         "Days before a review is due when its reminder becomes available."},
        {"minimum_cohort", :integer, 2, 1000, "Effectiveness disclosure minimum",
         "Minimum distinct employees and answered employees for a summary score."},
        {"report_days", :integer, 1, 3650, "Effectiveness reporting window",
         "Days ending today included in the company summary."},
        {"checkpoints", :array, nil, nil, "Effectiveness checkpoints",
         "Distinct positive day offsets after a session, captured by each published policy."}
      ],
      fn {key, type, min, max, label, help} ->
        {"people.training.evaluation." <> key,
         %{
           type: type,
           scopes: [:company],
           default: nil,
           nullable: true,
           minimum: min,
           maximum: max,
           label: label,
           help: help,
           capability: "people.training.evaluation.policy.manage"
         }}
      end
    )
  end
end
