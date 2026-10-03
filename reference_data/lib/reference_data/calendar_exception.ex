defmodule Bilimbi.People.ReferenceData.CalendarException do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_reference_data_calendar_overrides" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:on_date, :date)
    field(:label, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(exception, attributes) do
    exception
    |> cast(attributes, [:on_date, :label])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :on_date, :label])
    |> validate_length(:label, min: 1, max: 200)
    |> unique_constraint([:company_id, :on_date, :label],
      name: :people_reference_data_calendar_overrides_date_label_unique
    )
  end
end
