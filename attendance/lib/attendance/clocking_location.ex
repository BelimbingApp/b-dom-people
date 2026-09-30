defmodule Bilimbi.People.Attendance.ClockingLocation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Validation bound, not policy: a radius beyond this is not a location.
  @max_radius_meters 100_000

  schema "people_attendance_clocking_locations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:latitude, :decimal)
    field(:longitude, :decimal)
    field(:radius_meters, :integer)
    field(:status, :string, default: "active")
    timestamps(type: :naive_datetime)
  end

  def changeset(location, attrs) do
    location
    |> cast(attrs, [:code, :name, :latitude, :longitude, :radius_meters])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :code,
      :name,
      :latitude,
      :longitude,
      :radius_meters
    ])
    |> validate_length(:code, min: 1, max: 40)
    |> validate_format(:code, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:radius_meters, greater_than: 0, less_than_or_equal_to: @max_radius_meters)
    |> unique_constraint([:company_id, :code],
      name: :people_attendance_clocking_locations_company_code_unique
    )
  end

  def status_changeset(location, status) when status in ~w(active retired),
    do: change(location, status: status)

  @earth_radius_meters 6_371_008.8

  @doc "Great-circle distance in meters from the location's center."
  def distance_meters(%__MODULE__{latitude: lat, longitude: lon}, latitude, longitude) do
    {lat1, lon1} = {radians(lat), radians(lon)}
    {lat2, lon2} = {radians(latitude), radians(longitude)}

    a =
      :math.pow(:math.sin((lat2 - lat1) / 2), 2) +
        :math.cos(lat1) * :math.cos(lat2) * :math.pow(:math.sin((lon2 - lon1) / 2), 2)

    2 * @earth_radius_meters * :math.asin(min(1.0, :math.sqrt(a)))
  end

  defp radians(%Decimal{} = value), do: radians(Decimal.to_float(value))
  defp radians(value), do: value * :math.pi() / 180
end
