defmodule Bilimbi.People.Skills.Scale do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_skill_scales" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:version, :integer)
    field(:status, :string)
    field(:published_at, :naive_datetime)
    field(:retired_at, :naive_datetime)
    field(:actor_user_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(scale, attrs) do
    scale
    |> cast(attrs, [:code, :name])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :name, :version, :status])
    |> Bilimbi.People.Skills.Code.validate(:code)
    |> validate_length(:name, max: 160)
    |> unique_constraint([:company_id, :code], name: :people_skill_scales_one_draft)
    |> unique_constraint([:company_id, :code, :version],
      name: :people_skill_scales_code_version_unique
    )
  end
end
