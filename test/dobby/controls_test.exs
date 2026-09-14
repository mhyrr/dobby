defmodule Dobby.ControlsTest do
  @moduledoc """
  The direct control path, with no device type named on it.

  The thread lines a card writes are proven in `Dobby.InterventionsTest`; what
  is pinned here is the lookup — that a card fires exactly what the device's
  own module offers, typed by the action's own schema, and refused in the
  device's own words.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Controls

  @heater "water_heater:tank"

  setup do
    seed_house(%{
      "water_heater.tank" => %{
        state: "eco",
        attributes: %{
          current_temperature: 118,
          temperature: 120,
          min_temp: 90,
          max_temp: 150,
          supported_features: 15,
          operation_list: ["eco", "gas", "off"],
          away_mode: "off"
        }
      }
    })

    :ok
  end

  # The agent has the only opinion on the value. A card cannot set a
  # temperature a sentence could not, and the reason is the heater's.
  test "a value the device refuses is held with the device's own reason" do
    assert {:held, reason} =
             Controls.command(@heater, "set_temperature", "200", via: "greg, card")

    assert reason =~ "maximum of 150"
    assert Fake.trace() == []
  end

  test "the browser's string becomes the number the action declares" do
    assert {:ok, %{target_temperature_f: 125.0}} =
             Controls.command(@heater, "set_temperature", "125", via: "greg, card")

    assert_receive {:ha_call,
                    %HACall{entity_id: "water_heater.tank", data: %{temperature: 125.0}}},
                   2_000
  end

  test "an action the device has not offered is not fired" do
    # A read-only appliance offers nothing, so nothing can be posted at it.
    assert {:error, reason} = Controls.command("dishwasher:kitchen", "set_temperature", "1")
    assert reason =~ "offers no control"

    # And an unknown device is refused with the roll call, the way a schedule is.
    assert {:error, reason} = Controls.command("stove:kitchen", "set_temperature", "1")
    assert reason =~ "unknown device"
    assert Fake.trace() == []
  end

  test "a value the action cannot type is refused before the device hears it" do
    assert {:error, reason} = Controls.command(@heater, "set_temperature", "warm")
    assert reason =~ "temperature_f"
    assert Fake.trace() == []
  end
end
