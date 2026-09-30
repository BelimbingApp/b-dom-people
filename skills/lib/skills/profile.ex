defmodule Bilimbi.People.Skills.Profile do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skill_profiles" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:version, :integer)
    field(:status, :string)
    field(:scale_id, :integer)
    field(:effective_from, :date)
    field(:effective_to, :date)
    field(:published_at, :naive_datetime)
    field(:retired_at, :naive_datetime)
    field(:actor_user_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:code, :name, :scale_id])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :name, :version, :status, :scale_id])
    |> Bilimbi.People.Skills.Code.validate(:code)
    |> validate_length(:name, max: 160)
    |> unique_constraint([:company_id, :code], name: :people_skill_profiles_one_draft)
    |> unique_constraint([:company_id, :code, :version],
      name: :people_skill_profiles_code_version_unique
    )
  end
end
