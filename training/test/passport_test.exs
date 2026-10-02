defmodule Bilimbi.People.Training.PassportTest do
  use ExUnit.Case, async: true
  alias Bilimbi.People.Training.Passport
  alias Bilimbi.People.Workforce.ReadResult
  test "freshness warnings preserve Workforce's current, stale and unavailable contract" do
    assert Passport.workforce_warning(ReadResult.current([])) == nil
    warning = Passport.workforce_warning(ReadResult.stale([], ~U[2026-10-01 00:00:00Z]))
    assert warning =~ "stale"
    assert warning =~ "2026-10-01T00:00:00Z"
    assert warning =~ "Team access and document generation require current"
    assert Passport.workforce_warning(ReadResult.unavailable(:disconnected)) =~ "unavailable"
  end
end
