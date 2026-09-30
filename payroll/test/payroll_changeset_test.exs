defmodule Bilimbi.People.Payroll.ChangesetTest do
  use ExUnit.Case, async: true
  alias Bilimbi.People.Payroll.{Classification, Item, Mapping, Period}

  test "malformed dates and missing fields return changesets" do
    for schema <- [Classification, Item, Mapping, Period] do
      refute schema.changeset(struct(schema), %{}).valid?

      refute schema.changeset(struct(schema), %{
               effective_from: "invalid",
               effective_to: "2026-12-31",
               starts_on: "invalid",
               ends_on: "2026-12-31"
             }).valid?
    end
  end

  test "money refuses binary floating point" do
    changeset =
      Item.changeset(%Item{}, %{
        code: "item-a",
        name: "Item A",
        classification_id: 1,
        currency: "AAA",
        amount: 0.1,
        effective_from: "2026-01-01"
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :amount)
  end
end
