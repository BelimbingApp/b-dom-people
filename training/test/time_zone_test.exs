defmodule Bilimbi.People.Training.TimeZoneTest do
  use ExUnit.Case, async: true
  alias Bilimbi.People.Training

  test "named zones normalize across dates and refuse invalid zones" do
    assert {:ok, ~U[2026-01-01 15:00:00Z]} =
             Training.local_instant("2026-01-02T00:00", "Asia/Tokyo")

    assert {:ok, ~U[2026-07-01 13:00:00Z]} =
             Training.local_instant("2026-07-01T09:00", "America/New_York")

    assert {:error, :invalid_time_zone_or_time} =
             Training.local_instant("2026-01-01T09:00", "Invalid/Zone")

    assert {:error, :invalid_time_zone_or_time} = Training.local_instant("invalid", "UTC")
  end

  test "DST gaps and overlaps never silently select an instant" do
    assert {:error, :nonexistent_time} =
             Training.local_instant("2026-03-08T02:30", "America/New_York")

    assert {:error, :ambiguous_time} =
             Training.local_instant("2026-11-01T01:30", "America/New_York")
  end

  test "calendar day starts resolve midnight DST overlaps and gaps" do
    assert {:error, :ambiguous_time} =
             Training.local_instant("2026-11-01T00:00", "America/Havana")

    assert {:ok, ~U[2026-11-01 04:00:00Z]} =
             Training.day_start(~D[2026-11-01], "America/Havana")

    assert {:error, :nonexistent_time} =
             Training.local_instant("2026-03-08T00:00", "America/Havana")

    assert {:ok, ~U[2026-03-08 05:00:00Z]} =
             Training.day_start(~D[2026-03-08], "America/Havana")

    assert {:ok, ~U[2026-07-01 04:00:00Z]} =
             Training.day_start(~D[2026-07-01], "America/New_York")

    assert {:error, :invalid_time_zone_or_time} =
             Training.day_start(~D[2026-07-01], "Invalid/Zone")
  end
end
