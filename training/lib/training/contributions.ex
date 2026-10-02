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
        verbs: ["recommend", "answer", "generate"],
        capabilities:
          ~w(people.training.learning.view people.training.records.workspace.view people.training.passport.my.view people.training.passport.team.view people.training.passport.generate people.training.insights.view people.training.courses.view people.training.courses.manage people.training.sessions.view people.training.sessions.manage people.training.records.view people.training.records.manage people.training.evidence.manage people.training.retention.manage people.training.requests.submit people.training.requests.recommend people.training.requests.review people.training.requests.approve people.training.requests.view people.training.plans.submit people.training.plans.approve people.training.plans.view people.training.budgets.view people.training.budgets.manage people.training.effectiveness.view people.training.evaluation.submit people.training.effectiveness.answer people.training.effectiveness.summary.view people.training.evaluation.policy.manage people.training.evaluation.reminders.manage)
      },
      menu: training_menu() ++ effectiveness_menu()
    }
  end

  def training_menu do
    Enum.map(
      [
        {"people.my_work.my_learning", "My learning", "people.my_work", "/people/training/my",
         "people.training.learning.view", "user-circle", 40},
        {"people.development.courses", "Courses", "people.development",
         "/people/training/courses", "people.training.courses.view", "building-library", 60},
        {"people.development.sessions", "Sessions & calendar", "people.development",
         "/people/training/sessions", "people.training.sessions.view", "squares-2x2", 70},
        {"people.development.learning_reviews", "Learning requests & reviews",
         "people.development", "/people/training/requests", "people.training.requests.view",
         "clipboard-document-list", 75},
        {"people.development.training_records", "Training records", "people.development",
         "/people/training/records", "people.training.records.workspace.view",
         "clipboard-document-list", 80},
        {"people.reports.learning_insights", "Learning insights", "people.reports",
         "/people/training/insights", "people.training.insights.view", "chart-bar", 20},
        {"people.settings.learning_policy", "Learning policy and budgets", "people.settings",
         "/people/training/budgets", "people.training.budgets.view", "cog-6-tooth", 60}
      ],
      fn {id, label, parent, route, capability, icon, order} ->
        %{
          id: id,
          label: label,
          parent: parent,
          route: route,
          capability: capability,
          icon: icon,
          order: order
        }
      end
    )
  end

  def effectiveness_menu do
    [
      %{
        id: "people.development.effectiveness",
        label: "Effectiveness",
        parent: "people.development",
        route: "/people/training/effectiveness",
        capability: "people.training.effectiveness.view",
        icon: "chart-bar",
        order: 90
      }
    ]
  end

  defp policy_settings do
    Map.new(
      [
        {"evaluation_days", :integer, nil, 0, 3650, "Evaluation due days",
         "Days after the session ends when employee evaluation is due."},
        {"reminder_days", :integer, nil, 0, 3650, "Evaluation reminder lead",
         "Days before a review is due when its reminder becomes available."},
        {"minimum_cohort", :integer, nil, 2, 1000, "Effectiveness disclosure minimum",
         "Minimum distinct employees and answered employees for a summary score."},
        {"report_months", :integer, 3, 1, 12, "Effectiveness reporting period",
         "Months per fixed summary period; 12 must divide evenly by it. 3 is a calendar quarter. A changed length applies from the day after the last frozen period; Effectiveness shows that date."},
        {"report_grace_days", :integer, nil, 0, 3650, "Effectiveness answer grace",
         "Days after a reporting period ends before its summary is frozen permanently."},
        {"checkpoints", :array, nil, nil, nil, "Effectiveness checkpoints",
         "Distinct positive day offsets after a session, captured by each published policy."}
      ],
      fn {key, type, default, min, max, label, help} ->
        {"people.training.evaluation." <> key,
         %{
           type: type,
           scopes: [:company],
           default: default,
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
