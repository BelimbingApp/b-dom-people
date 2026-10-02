defmodule Bilimbi.People.Workforce.PositionsAvailabilityTest do
  use ExUnit.Case, async: false

  alias Bilimbi.People.Workforce

  setup do
    key = {Workforce, :position_reader}
    original = :persistent_term.get(key, nil)
    if original != nil, do: Workforce.unregister_position_reader(original)

    on_exit(fn ->
      :persistent_term.erase(key)
      if original != nil, do: Workforce.register_position_reader(original)
    end)
  end

  test "positions are unavailable without a registered reader" do
    refute Workforce.positions_available?()
  end

  test "positions are available while a reader is registered" do
    assert :ok = Workforce.register_position_reader(__MODULE__)
    assert Workforce.positions_available?()

    assert :ok = Workforce.unregister_position_reader(__MODULE__)
    refute Workforce.positions_available?()
  end

  test "unregistering a replaced reader preserves the current reader" do
    assert :ok = Workforce.register_position_reader(__MODULE__)
    assert :ok = Workforce.register_position_reader(Workforce)
    assert Workforce.positions_available?()

    assert :ok = Workforce.unregister_position_reader(__MODULE__)
    assert Workforce.positions_available?()

    assert :ok = Workforce.unregister_position_reader(Workforce)
    refute Workforce.positions_available?()
  end
end
