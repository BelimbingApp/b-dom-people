defmodule Bilimbi.People.Skills.ProfileItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @criticalities ~w(critical essential development)

  schema "people_skill_profile_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:profile_id, :integer)
    field(:skill_id, :integer)
    field(:sequence, :integer)
    field(:required_level, :integer)
    field(:criticality, :string)
    field(:weight_percent, :decimal)
    field(:mandatory, :boolean, default: false)
    field(:evidence_standard, :string)
    timestamps(type: :naive_datetime)
  end

  def criticalities, do: @criticalities

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :required_level,
      :criticality,
      :weight_percent,
      :mandatory,
      :evidence_standard
    ])
    |> validate_required([
      :tenant_id,
      :company_id,
      :profile_id,
      :skill_id,
      :sequence,
      :required_level,
      :criticality,
      :weight_percent,
      :mandatory
    ])
    |> validate_number(:required_level, greater_than_or_equal_to: 0, less_than_or_equal_to: 20)
    |> validate_inclusion(:criticality, @criticalities)
    |> validate_number(:weight_percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_change(:weight_percent, fn :weight_percent, weight ->
      if Decimal.eq?(Decimal.round(weight, 2), weight),
        do: [],
        else: [weight_percent: "has at most two decimals"]
    end)
    |> validate_length(:evidence_standard, max: 2000)
    |> unique_constraint([:profile_id, :skill_id],
      name: :people_skill_profile_items_profile_skill_unique
    )
  end
end
