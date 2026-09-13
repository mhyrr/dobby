defmodule Dobby.DeviceAgents.LibraryTest do
  @moduledoc """
  The common Home Assistant device library (TK-014).

  These scenarios exercise the shared boundary, live agents, closed tools,
  and FakeHA confirm loop. No model participates.
  """

  use Dobby.RigCase, async: false

  alias Dobby.HomeConfig.Types
  alias Dobby.Tools

  test "the registry names semantic types rather than vendors or raw HA buckets" do
    assert Types.names() == [
             "thermostat",
             "dishwasher",
             "oven",
             "refrigerator",
             "washer",
             "dryer",
             "water_heater",
             "humidifier",
             "dehumidifier",
             "air_purifier",
             "range_hood",
             "coffee_maker",
             "wine_cooler",
             "ice_maker",
             "cooktop",
             "microwave",
             "light",
             "speaker",
             "camera",
             "doorbell",
             "lock",
             "access_cover",
             "power_switch",
             "shade",
             "fan",
             "environment_monitor",
             "contact_sensor",
             "occupancy_sensor",
             "safety_sensor",
             "vacuum",
             "wifi_endpoint"
           ]

    refute Enum.any?(Types.names(), &(&1 in ["sonos", "ring", "nest", "media_player", "sensor"]))
  end

  test "secure types expose safe-direction actions and no inverse" do
    assert Dobby.DeviceAgents.Lock.tools() == [Tools.LockGetStatus, Tools.LockSecure]

    assert Dobby.DeviceAgents.AccessCover.tools() == [
             Tools.AccessCoverGetStatus,
             Tools.AccessCoverClose
           ]

    names = Enum.map(Dobby.Home.library(), & &1.name())
    assert "lock_secure" in names
    assert "access_cover_close" in names
    refute Enum.any?(names, &(&1 in ["lock_unlock", "access_cover_open"]))
  end

  test "an unavailable lock and an unsupported speaker action stop before Home Assistant" do
    boot_house!([
      device("lock:front", "front door lock", Dobby.DeviceAgents.Lock, %{lock: "lock.front"}),
      device("speaker:kitchen", "kitchen speaker", Dobby.DeviceAgents.Speaker, %{
        media_player: "media_player.kitchen"
      })
    ])

    seed_house(%{
      "lock.front" => %{state: "unavailable", attributes: %{}},
      "media_player.kitchen" => %{
        state: "idle",
        attributes: %{supported_features: 0}
      }
    })

    assert {:ok, %{accepted: false, reason: lock_reason}} =
             Jido.Exec.run(Tools.LockSecure, %{device: "lock:front"})

    assert lock_reason =~ "unavailable"

    assert {:ok, %{accepted: false, reason: speaker_reason}} =
             Jido.Exec.run(Tools.SpeakerPlay, %{device: "speaker:kitchen"})

    assert speaker_reason =~ "does not support play"
    assert Fake.trace() == []
  end

  test "speaker, lock, access cover, switch, fan, and shade commands complete through FakeHA" do
    devices = [
      device("speaker:kitchen", "kitchen speaker", Dobby.DeviceAgents.Speaker, %{
        media_player: "media_player.kitchen"
      }),
      device("lock:front", "front door lock", Dobby.DeviceAgents.Lock, %{lock: "lock.front"}),
      device("cover:garage", "garage door", Dobby.DeviceAgents.AccessCover, %{
        cover: "cover.garage"
      }),
      device("switch:porch", "porch outlet", Dobby.DeviceAgents.PowerSwitch, %{
        switch: "switch.porch"
      }),
      device("fan:bedroom", "bedroom fan", Dobby.DeviceAgents.Fan, %{fan: "fan.bedroom"}),
      device("shade:office", "office shade", Dobby.DeviceAgents.Shade, %{cover: "cover.office"})
    ]

    boot_house!(devices)

    seed_house(%{
      "media_player.kitchen" => %{
        state: "paused",
        attributes: %{volume_level: 0.3, supported_features: 16_389}
      },
      "lock.front" => %{state: "unlocked", attributes: %{}},
      "cover.garage" => %{state: "open", attributes: %{current_position: 100}},
      "switch.porch" => %{state: "on", attributes: %{}},
      "fan.bedroom" => %{state: "on", attributes: %{percentage: 40, supported_features: 1}},
      "cover.office" => %{
        state: "open",
        attributes: %{current_position: 50, supported_features: 4}
      }
    })

    assert_accepted(
      Tools.SpeakerPlay,
      %{device: "speaker:kitchen"},
      "media_player",
      "media_play",
      "Play",
      false
    )

    assert_accepted(Tools.LockSecure, %{device: "lock:front"}, "lock", "lock", "Locked")

    assert_accepted(
      Tools.AccessCoverClose,
      %{device: "cover:garage"},
      "cover",
      "close_cover",
      "Closed"
    )

    assert_accepted(
      Tools.PowerSwitchTurnOff,
      %{device: "switch:porch"},
      "switch",
      "turn_off",
      "Off"
    )

    assert_accepted(
      Tools.FanSetSpeed,
      %{device: "fan:bedroom", speed_percent: 65},
      "fan",
      "set_percentage",
      "65%"
    )

    assert_accepted(
      Tools.ShadeSetPosition,
      %{device: "shade:office", position: 20},
      "cover",
      "set_cover_position",
      "20%"
    )

    assert agent_state("speaker:kitchen").playback == :playing
    assert agent_state("lock:front").lock_state == :locked
    assert agent_state("cover:garage").cover_state == :closed
    assert agent_state("switch:porch").power == :off
    assert agent_state("fan:bedroom").speed_percent == 65
    assert agent_state("shade:office").position == 20
  end

  test "compound and read-only devices report from deterministic state" do
    devices = [
      device("doorbell:front", "front doorbell", Dobby.DeviceAgents.Doorbell, %{
        event: "event.front_door",
        camera: "camera.front_door",
        motion: "binary_sensor.front_motion"
      }),
      device("monitor:office", "office air", Dobby.DeviceAgents.EnvironmentMonitor, %{
        temperature: "sensor.office_temperature",
        humidity: "sensor.office_humidity"
      }),
      device("contact:patio", "patio door", Dobby.DeviceAgents.ContactSensor, %{
        contact: "binary_sensor.patio_door"
      }),
      device("occupancy:hall", "hall occupancy", Dobby.DeviceAgents.OccupancySensor, %{
        occupancy: "binary_sensor.hall_occupancy"
      }),
      device("safety:basement", "basement smoke", Dobby.DeviceAgents.SafetySensor, %{
        alarm: "binary_sensor.basement_smoke"
      })
    ]

    boot_house!(devices)

    seed_house(%{
      "event.front_door" => %{
        state: "2026-08-23T12:00:00+00:00",
        attributes: %{event_type: "ring", device_class: "doorbell"}
      },
      "camera.front_door" => %{state: "idle", attributes: %{}},
      "binary_sensor.front_motion" => %{state: "on", attributes: %{device_class: "motion"}},
      "sensor.office_temperature" => %{
        state: "72.4",
        attributes: %{device_class: "temperature", unit_of_measurement: "°F"}
      },
      "sensor.office_humidity" => %{
        state: "41",
        attributes: %{device_class: "humidity", unit_of_measurement: "%"}
      },
      "binary_sensor.patio_door" => %{state: "off", attributes: %{device_class: "door"}},
      "binary_sensor.hall_occupancy" => %{
        state: "on",
        attributes: %{device_class: "occupancy"}
      },
      "binary_sensor.basement_smoke" => %{
        state: "off",
        attributes: %{device_class: "smoke"}
      }
    })

    assert {:ok, doorbell} = Jido.Exec.run(Tools.DoorbellGetStatus, %{device: "doorbell:front"})
    assert doorbell.last_event == "ring"
    assert doorbell.camera_available
    assert doorbell.motion

    assert {:ok, monitor} =
             Jido.Exec.run(Tools.EnvironmentMonitorGetStatus, %{device: "monitor:office"})

    assert monitor.readings == %{temperature: 72.4, humidity: 41.0}
    assert monitor.units == %{temperature: "°F", humidity: "%"}

    assert {:ok, %{open: false}} =
             Jido.Exec.run(Tools.ContactSensorGetStatus, %{device: "contact:patio"})

    assert {:ok, %{occupied: true}} =
             Jido.Exec.run(Tools.OccupancySensorGetStatus, %{device: "occupancy:hall"})

    assert {:ok, %{alarm: false, hazard: :smoke}} =
             Jido.Exec.run(Tools.SafetySensorGetStatus, %{device: "safety:basement"})

    assert Fake.trace() == []
  end

  test "every status tool names the device under `device` and never repeats the snapshot's `id`" do
    boot_house!(Enum.map(Types.modules(), &contract_device/1))

    for module <- Types.modules(),
        tool <- module.tools(),
        String.ends_with?(tool.name(), "_get_status") do
      id = contract_device_id(module)
      assert {:ok, status} = Jido.Exec.run(tool, %{device: id})

      # `device` is the word the whole tool library answers in, and the model
      # reads a result key by key. A status tool that handed its snapshot
      # straight back would say `id` instead, or say both — and a tool that
      # names the same thing differently from its neighbours is a contract
      # that lies to the model about what a device reference is called.
      assert Map.get(status, :device) == id,
             "#{tool.name()} must name the device under `device`"

      refute Map.has_key?(status, :id),
             "#{tool.name()} returns the snapshot's `id`; the library answers in `device`"
    end
  end

  # One device per registered type, from the fixture that type's own contract
  # test already declares, so a new type joins this check by existing rather
  # than by being remembered here. Entity names are rewritten per type because
  # every fixture says "contract" and one house cannot bind an entity twice.
  defp contract_device(module) do
    fixture = Dobby.DeviceAgentContract.fixture(module)
    bindings = Keyword.fetch!(fixture, :bindings)

    %{
      id: contract_device_id(module),
      name: "contract #{module.config_type()}",
      aliases: [],
      agent_module: module,
      bindings:
        Map.new(bindings, fn {key, entity} ->
          [domain, _name] = String.split(entity, ".", parts: 2)
          {key, "#{domain}.#{module.config_type()}_#{key}"}
        end),
      settings: Keyword.get(fixture, :settings, %{})
    }
  end

  defp contract_device_id(module), do: "#{module.config_type()}:contract"

  defp assert_accepted(tool, args, domain, service, reading, commanded? \\ true) do
    assert {:ok, %{accepted: true, device: device, name: name} = result} =
             Jido.Exec.run(tool, args)

    assert is_binary(device) and is_binary(name)

    # The thread's record line is written from this exact shape:
    # `Dobby.Conversation.Turn` matches on accepted/device/name, and
    # `Interventions.reading/1` renders the commanded value. A write result
    # the thread cannot read is a command the thread never mentions — and
    # the expected string matters: a truthy assert once passed on "Nil".
    assert Dobby.Interventions.reading(result) == reading

    assert_receive {:ha_call, %HACall{domain: ^domain, service: ^service}}, 2_000

    # Other devices can still have echoes in the mailbox. Only this device's
    # event proves its asynchronous state update arrived before we read it.
    assert_receive %Jido.Signal{
                     type: "dobby.device.state_changed",
                     data: %{commanded?: ^commanded?, snapshot: %{id: ^device}}
                   },
                   2_000
  end

  defp device(id, name, module, bindings) do
    %{
      id: id,
      name: name,
      aliases: [],
      agent_module: module,
      bindings: bindings,
      settings: %{}
    }
  end
end
