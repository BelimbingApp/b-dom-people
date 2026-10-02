defmodule Bilimbi.People.Training.Web.MenuTest do
  use ExUnit.Case, async: true
  alias Bilimbi.Base.Menu
  test "Training navigation uses the outline groups and one destination per workflow" do
    expected = [
      {"My learning", "people.my_work", "/people/training/my"},
      {"Courses", "people.development", "/people/training/courses"},
      {"Sessions & calendar", "people.development", "/people/training/sessions"},
      {"Learning requests & reviews", "people.development", "/people/training/requests"},
      {"Training records", "people.development", "/people/training/records"},
      {"Effectiveness", "people.development", "/people/training/effectiveness"},
      {"Learning insights", "people.reports", "/people/training/insights"},
      {"Learning policy and budgets", "people.settings", "/people/training/budgets"}
    ]
    entries = Enum.filter(Menu.items(), &String.starts_with?(&1.route || "", "/people/training"))
    assert Enum.sort(Enum.map(entries, &{&1.label, &1.parent, &1.route})) == Enum.sort(expected)
    refute Enum.any?(entries, &String.contains?(&1.label, "Passport"))
    assert Enum.count(entries, &(&1.label == "Effectiveness")) == 1
    assert Enum.all?(entries, &is_binary(&1.capability))
    granted = Menu.visible_tree(fn capability -> capability == "people.training.insights.view" end)
    assert find(granted, "people.reports.learning_insights")
    refute find(granted, "people.development.courses")
    refute find(Menu.visible_tree(fn _ -> false end), "people.reports")
  end
  defp find(nodes, id), do: Enum.any?(nodes, fn node -> node.item.id == id or find(node.children, id) end)
end
