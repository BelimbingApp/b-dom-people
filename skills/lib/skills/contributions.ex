defmodule Bilimbi.People.Skills.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @policy "people.skills.policy.manage"

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          "people.skills.reassessment_due_days" =>
            integer(
              30,
              1,
              365,
              "Reassessment request window",
              "Days after a team lead requests a reassessment by which it falls due."
            ),
          "people.skills.default_reassessment_months" =>
            integer(
              12,
              1,
              120,
              "Default reassessment interval",
              "Months after an assessment when the skill is next due, for a skill with no interval of its own and an assessment with no validity date."
            ),
          "people.skills.reminder_window_days" =>
            integer(
              30,
              0,
              365,
              "Validity reminder window",
              "Days before a skill's validity ends that its reminder becomes due."
            ),
          "people.skills.backup_minimum" =>
            integer(
              2,
              1,
              100,
              "Critical-skill backup minimum",
              "Employees who must hold a critical skill at their required level before it counts as covered."
            ),
          "people.skills.priority_multiplier_critical" =>
            integer(
              3,
              0,
              100,
              "Critical priority multiplier",
              "Multiplies a critical requirement's gap into its priority score."
            ),
          "people.skills.priority_multiplier_essential" =>
            integer(
              2,
              0,
              100,
              "Essential priority multiplier",
              "Multiplies an essential requirement's gap into its priority score."
            ),
          "people.skills.priority_multiplier_development" =>
            integer(
              1,
              0,
              100,
              "Development priority multiplier",
              "Multiplies a development requirement's gap into its priority score."
            )
        },
        runtime_claims: []
      },
      authz: %{
        domains: %{"people" => "People domain modules"},
        capabilities: [
          "people.skills.catalog.view",
          "people.skills.catalog.manage",
          "people.skills.profiles.publish",
          "people.skills.assessments.view",
          "people.skills.assessments.submit",
          "people.skills.assessments.review",
          "people.skills.assessments.approve",
          "people.skills.assessments.manage",
          "people.skills.reassessments.submit",
          "people.skills.reassessments.execute",
          "people.skills.actions.view",
          "people.skills.actions.update",
          "people.skills.actions.manage",
          "people.skills.actions.approve",
          "people.skills.self.view",
          "people.skills.reminders.send",
          @policy
        ]
      },
      menu: [
        %{
          id: "people.my_work.skills",
          label: "My skills",
          icon: "puzzle-piece",
          parent: "people.my_work",
          route: "/people/skills/my",
          capability: "people.skills.self.view",
          order: 40
        },
        %{
          id: "people.development.skills",
          label: "Skills",
          icon: "puzzle-piece",
          parent: "people.development",
          route: "/people/skills",
          capability: "people.skills.catalog.view",
          order: 10
        },
        %{
          id: "people.development.assessments",
          label: "Assessments",
          icon: "clipboard-document-list",
          parent: "people.development",
          route: "/people/skills/assessments",
          capability: "people.skills.assessments.view",
          order: 20
        },
        %{
          id: "people.development.actions",
          label: "Development actions",
          icon: "flag",
          parent: "people.development",
          route: "/people/skills/actions",
          capability: "people.skills.actions.view",
          order: 30
        },
        %{
          id: "people.settings.skills_policy",
          label: "Skills policy",
          icon: "cog-6-tooth",
          parent: "people.settings",
          route: "/people/skills/policy",
          capability: @policy,
          order: 40
        }
      ]
    }
  end

  defp integer(default, minimum, maximum, label, help),
    do: %{
      type: :integer,
      scopes: [:company],
      default: default,
      minimum: minimum,
      maximum: maximum,
      label: label,
      help: help,
      capability: @policy
    }
end
