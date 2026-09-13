defmodule DobbyWeb.FlapTest do
  @moduledoc """
  The board's vocabulary, read straight from device snapshots.

  These are the sentences the surface says on Dobby's behalf, so they carry
  the same rule his replies do: report what was commanded, never what was
  observed about the room.
  """

  use ExUnit.Case, async: true

  import DobbyWeb.Flap, only: [read: 1]

  describe "a thermostat" do
    test "holding its setpoint is SET" do
      assert %{word: "Set", state: :set, value: "70°"} =
               read(thermostat(current: 70, target: 70))
    end

    test "closing a gap upward is WARMING" do
      assert %{word: "Warming", state: :acting} = read(thermostat(current: 64, target: 70))
    end

    test "closing a gap downward is COOLING" do
      assert %{word: "Cooling", state: :acting} =
               read(thermostat(current: 76, target: 70, hvac_mode: :cool))
    end

    test "a heating thermostat above its setpoint is not COOLING" do
      # It is a furnace, not an air conditioner. The word has to come from
      # what the device can actually do, or the board is inventing a state
      # nobody commanded.
      assert %{word: "Set"} = read(thermostat(current: 76, target: 70, hvac_mode: :heat))
    end

    test "sitting within half a degree does not flap between words" do
      # A thermostat resting on its setpoint wobbles. A board that flipped
      # between SET and WARMING every few minutes would be describing the
      # sensor rather than the house.
      assert %{word: "Set"} = read(thermostat(current: 69.7, target: 70))
    end

    test "unavailable is QUIET, and unset is NOT KNOWN" do
      assert %{word: "Quiet", state: :silent} = read(thermostat(available: false))

      assert %{word: "Not known", state: :silent} =
               read(thermostat(current: 68, target: nil))
    end

    test "not yet heard from is NOT KNOWN, the same as an endpoint" do
      # The distinction the endpoint has always drawn, now drawn here too:
      # "nobody has told us" is not "it stopped answering". A thermostat that
      # has only just come up said QUIET before `available` defaulted to nil,
      # which was the board announcing a device down every time the box booted.
      assert %{word: "Not known", state: :silent} = read(thermostat(available: nil))
    end
  end

  describe "an endpoint" do
    test "answering is AWAKE" do
      assert %{word: "Awake", state: :acting} = read(endpoint(online: true))
    end

    test "not answering is QUIET" do
      assert %{word: "Quiet", state: :silent} = read(endpoint(online: false))
    end

    test "not yet heard from is NOT KNOWN, which is not the same as offline" do
      # `wifi_get_status` insists on this distinction to the model. A board
      # that said QUIET for both would be the surface contradicting the tool.
      assert %{word: "Not known", state: :silent} = read(endpoint(online: nil))
      assert %{word: "Not known", state: :silent} = read(endpoint(available: false))
    end
  end

  describe "the device library" do
    test "secure devices report observed state as AWAKE, not as a command" do
      assert %{word: "Awake", state: :acting, value: "Locked"} =
               read(%{type: :lock, available: true, lock_state: :locked})

      assert %{word: "Awake", state: :acting, value: "Open"} =
               read(%{type: :access_cover, available: true, cover_state: :open})
    end

    test "sensors put the reading beside the closed vocabulary" do
      assert %{word: "Awake", value: "Open"} =
               read(%{type: :contact_sensor, available: true, open: true})

      assert %{word: "Awake", value: "Alarm"} =
               read(%{type: :safety_sensor, available: true, alarm: true})

      assert %{word: "Awake", value: "72.4°F"} =
               read(%{
                 type: :environment_monitor,
                 available: true,
                 readings: %{temperature: 72.4},
                 units: %{temperature: "°F"}
               })
    end

    test "reversible actors use SET and retain their concrete reading" do
      assert %{word: "Set", state: :set, value: "Off"} =
               read(%{type: :power_switch, available: true, power: :off})

      assert %{word: "Set", state: :set, value: "40%"} =
               read(%{type: :fan, available: true, power: :on, speed_percent: 40})
    end
  end

  describe "an appliance that only reads" do
    # AWAKE, the same word the sensors take, because that is the whole of what
    # these types can say: the endpoint answers, and this is what it answered.

    test "a dishwasher says which cycle it is in" do
      assert %{word: "Awake", state: :acting, value: "Run"} =
               read(appliance(:dishwasher, %{operation_state: "Run"}))
    end

    test "an oven says how hot it is" do
      assert %{word: "Awake", value: "350°F"} =
               read(
                 appliance(:oven, %{temperature: 350.0, operation_state: "run"},
                   units: %{temperature: "°F"}
                 )
               )
    end

    test "a refrigerator says what its fresh compartment reads" do
      assert %{word: "Awake", value: "38°F"} =
               read(
                 appliance(
                   :refrigerator,
                   %{refrigerator_display_temperature: 38.0, freezer_display_temperature: 2.0},
                   units: %{
                     refrigerator_display_temperature: "°F",
                     freezer_display_temperature: "°F"
                   }
                 )
               )
    end

    test "a stored target never stands in for a missing measurement" do
      # `Dobby.DeviceAgents.Refrigerator` says so about its own readings, and
      # the board has the stronger reason: the word beside this column is
      # AWAKE, so a setpoint printed here reads as what the fridge *is*. A
      # target belongs in this column only where the word is SET.
      assert %{word: "Awake", value: nil} =
               read(
                 appliance(
                   :refrigerator,
                   %{refrigerator_target_temperature: 37.0, freezer_target_temperature: 0.0},
                   units: %{
                     refrigerator_target_temperature: "°F",
                     freezer_target_temperature: "°F"
                   }
                 )
               )
    end

    test "a washer and a dryer say the same thing, because they are the same row" do
      assert %{word: "Awake", value: "Rinsing"} =
               read(appliance(:washer, %{operation_state: "rinsing"}))

      assert %{word: "Awake", value: "Drying"} =
               read(appliance(:dryer, %{operation_state: "drying"}))
    end

    test "a coffee maker says what it is doing" do
      assert %{word: "Awake", value: "Ready"} =
               read(appliance(:coffee_maker, %{operation_state: "ready"}))
    end

    test "a wine cooler says what it reads" do
      assert %{word: "Awake", value: "55°F"} =
               read(appliance(:wine_cooler, %{temperature: 55.0}, units: %{temperature: "°F"}))
    end

    test "an ice maker says what it is doing" do
      assert %{word: "Awake", value: "Idle"} =
               read(appliance(:ice_maker, %{operation_state: "idle"}))
    end

    test "a cooktop zone says what it is doing, then how hard" do
      assert %{word: "Awake", value: "Run"} =
               read(appliance(:cooktop, %{operation_state: "run", power_level: 60.0}))

      assert %{word: "Awake", value: "60%"} =
               read(appliance(:cooktop, %{power_level: 60.0}, units: %{power_level: "%"}))
    end

    test "a microwave says what it is doing, and how much of it is left" do
      assert %{word: "Awake", value: "Cooking"} =
               read(appliance(:microwave, %{operation_state: "cooking"}))

      assert %{word: "Awake", value: "90 s"} =
               read(appliance(:microwave, %{remaining_time: 90.0}, units: %{remaining_time: "s"}))
    end

    test "the door is the last thing a cycle appliance has to say" do
      assert %{word: "Awake", value: "Open"} =
               read(appliance(:dishwasher, %{door_open: true}))

      assert %{word: "Awake", value: "Closed"} =
               read(appliance(:washer, %{door_open: false}))
    end

    test "a reading somebody bound but nobody can say plainly leaves the column blank" do
      # The Absent Word Rule, carried from the flap to the reading beside it.
      # An ice bin that is not full is not the same as one that is empty — the
      # ice maker's own moduledoc refuses to invent the quantity — so the
      # column says nothing rather than inventing a phrase for it.
      assert %{word: "Awake", value: nil} = read(appliance(:ice_maker, %{ice_full: true}))
    end

    test "one that has stopped answering is QUIET, and keeps what it last said" do
      assert %{word: "Quiet", state: :silent, value: "Run"} =
               read(appliance(:dishwasher, %{operation_state: "Run"}, available: false))
    end

    test "one nobody has heard from is NOT KNOWN, which is a different fact" do
      # The defect this vocabulary exists to prevent: an appliance that has
      # stopped answering and one that has never reported are not the same
      # sentence, and neither of them is AWAKE.
      assert %{word: "Not known", state: :silent, value: nil} =
               read(appliance(:oven, %{temperature: nil}, available: nil))
    end
  end

  describe "an appliance that can be commanded" do
    test "a water heater somebody set to 120° is SET, not AWAKE" do
      # The inversion this clause was written for. Reading a commanded value as
      # an endpoint answering is the Commanded-Not-Observed Rule backwards, on
      # the one appliance row where the number matters most.
      assert %{word: "Set", state: :set, value: "120°"} =
               read(water_heater(target: 120.0, current: 118.0))
    end

    test "a water heater never shows the tank's own temperature" do
      # 118 is what the tank reads. Printing it beside SET would say somebody
      # asked for 118, which nobody did.
      assert %{word: "Set", value: "Eco"} =
               read(water_heater(target: nil, current: 118.0, mode: "eco"))

      assert %{word: "Set", value: "Off"} =
               read(water_heater(target: nil, current: 118.0, power: :off))
    end

    test "a humidifier and a dehumidifier show the humidity somebody asked for" do
      assert %{word: "Set", state: :set, value: "45%"} =
               read(humidity(:humidifier, target: 45, current: 38))

      assert %{word: "Set", state: :set, value: "50%"} =
               read(humidity(:dehumidifier, target: 50, current: 61))
    end

    test "the room's own humidity never fills the column" do
      assert %{word: "Set", value: "On"} =
               read(humidity(:humidifier, target: nil, current: 38, power: :on))
    end

    test "a purifier and a hood show the speed they were set to" do
      assert %{word: "Set", state: :set, value: "60%"} =
               read(ventilation(:air_purifier, speed: 60))

      assert %{word: "Set", state: :set, value: "40%"} =
               read(ventilation(:range_hood, speed: 40))
    end

    test "one with no speed to report falls back to the switch, and stays SET" do
      assert %{word: "Set", value: "On"} = read(ventilation(:range_hood, speed: nil, power: :on))
    end

    test "one that has stopped answering is QUIET, and one nobody has heard from is NOT KNOWN" do
      assert %{word: "Quiet", state: :silent} =
               read(water_heater(target: 120.0, available: false))

      assert %{word: "Not known", state: :silent} =
               read(water_heater(target: nil, available: nil))

      assert %{word: "Quiet", state: :silent} =
               read(humidity(:dehumidifier, target: 50, available: false))

      assert %{word: "Not known", state: :silent} =
               read(ventilation(:air_purifier, speed: nil, available: nil))
    end
  end

  describe "the board's own floor" do
    test "every registered device type has a word the moment it boots, and it is NOT KNOWN" do
      # Built the way production builds it — each module's own `initial_state`
      # and `snapshot`, through its own agent schema — because a fixture that
      # seeds what production builds would not have caught either half of this.
      #
      # A booted device has reported nothing, so the word is NOT KNOWN and the
      # column beside it is empty. Two things used to break that. Fifteen types
      # were registered with no clause here, so the first report they did get
      # said AWAKE with nothing beside it. And `nil` is an atom, so every type
      # whose reading came from an atom wrote the literal word "Nil" on the
      # board before Home Assistant had spoken.
      for module <- Dobby.HomeConfig.Types.modules() do
        assert %{word: "Not known", state: :silent, value: nil} = read(boot_snapshot(module)),
               "#{module.config_type()} does not say NOT KNOWN before the house has spoken"
      end
    end

    test "a type with no clause of its own still tells QUIET from NOT KNOWN" do
      # A registered type reaching the fallback is a bug rather than a default.
      # This is what the board says while somebody fixes it, and the one thing
      # it must not do is fold "stopped answering" into "nobody has told us".
      assert %{word: "Awake", state: :acting, value: nil} =
               read(%{type: :something_new, available: true})

      assert %{word: "Quiet", state: :silent, value: nil} =
               read(%{type: :something_new, available: false})

      assert %{word: "Not known", state: :silent, value: nil} =
               read(%{type: :something_new, available: nil})

      assert %{word: "Not known", state: :silent, value: nil} = read(%{type: :something_new})
    end
  end

  defp thermostat(opts) do
    %{
      id: "thermostat:main",
      name: "main thermostat",
      type: :thermostat,
      available: Keyword.get(opts, :available, true),
      current_temperature_f: Keyword.get(opts, :current),
      target_temperature_f: Keyword.get(opts, :target),
      hvac_mode: Keyword.get(opts, :hvac_mode, :heat)
    }
  end

  defp endpoint(opts) do
    %{
      id: "wifi:kitchen_tv",
      name: "kitchen TV",
      type: :wifi_endpoint,
      available: Keyword.get(opts, :available, true),
      online: Keyword.get(opts, :online),
      last_changed_at: nil
    }
  end

  # The shape `Dobby.DeviceAgents.ApplianceReadings` builds: the bound readings
  # and, beside them, the units Home Assistant sent with them.
  defp appliance(type, readings, opts \\ []) do
    %{
      id: "#{type}:kitchen",
      name: "kitchen #{type}",
      type: type,
      available: Keyword.get(opts, :available, true),
      readings: readings,
      units: Keyword.get(opts, :units, %{})
    }
  end

  defp water_heater(opts) do
    %{
      id: "water_heater:tank",
      name: "the tank",
      type: :water_heater,
      available: Keyword.get(opts, :available, true),
      power: Keyword.get(opts, :power),
      mode: Keyword.get(opts, :mode),
      away_mode: nil,
      current_temperature_f: Keyword.get(opts, :current),
      target_temperature_f: Keyword.get(opts, :target)
    }
  end

  defp humidity(type, opts) do
    %{
      id: "#{type}:nursery",
      name: "nursery #{type}",
      type: type,
      available: Keyword.get(opts, :available, true),
      power: Keyword.get(opts, :power, :on),
      current_humidity_percent: Keyword.get(opts, :current),
      target_humidity_percent: Keyword.get(opts, :target),
      units: %{current_humidity_percent: "%", target_humidity_percent: "%"}
    }
  end

  defp ventilation(type, opts) do
    %{
      id: "#{type}:kitchen",
      name: "kitchen #{type}",
      type: type,
      available: Keyword.get(opts, :available, true),
      power: Keyword.get(opts, :power, :on),
      speed_percent: Keyword.get(opts, :speed),
      supports_speed: true,
      readings: %{},
      units: %{}
    }
  end

  # A device the moment it starts and before Home Assistant has said anything:
  # the module's own initial state, through its own agent schema, read back
  # through its own snapshot. Production does exactly this at boot.
  defp boot_snapshot(module) do
    bindings = Map.new(module.subscribed_bindings(), &{&1, "sensor.#{&1}"})

    device = %Dobby.Home.Device{
      id: "#{module.config_type()}:flap",
      name: "a #{module.config_type()}",
      agent_module: module,
      bindings: bindings,
      settings: %{}
    }

    agent = module.new(id: device.id, state: module.initial_state(device))
    module.snapshot(agent.state)
  end
end
