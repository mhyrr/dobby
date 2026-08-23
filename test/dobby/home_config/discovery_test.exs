defmodule Dobby.HomeConfig.DiscoveryTest do
  @moduledoc """
  The discovery read (TK-010).

  Deterministic top to bottom: no model, no tool, no conversation. What this
  file pins is the subtraction — everything Home Assistant knows, minus what
  the manifest already claims, minus what no device type could manage — and the
  fact that the answer comes from the client's own memory rather than from a
  request somebody made on the model's behalf.
  """

  use Dobby.RigCase, async: false

  alias Dobby.HomeConfig.Discovery

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity()})
    :ok
  end

  describe "what is on offer" do
    test "an entity nobody has bound is a candidate, with the type it looks like" do
      Fake.put_entity("climate.dining_room", %{
        state: "heat",
        attributes: %{friendly_name: "Dining Room Nest"}
      })

      assert {:ok, candidates} = Discovery.candidates()

      assert [
               %{
                 entity_id: "climate.dining_room",
                 type: "thermostat",
                 binding: "climate",
                 suggested_name: "Dining Room Nest",
                 state: "heat"
               }
             ] = candidates
    end

    test "the entity this house already manages is not offered" do
      assert {:ok, candidates} = Discovery.candidates()

      refute Enum.any?(candidates, &(&1.entity_id == @entity))
      assert Discovery.bound?(@entity)
    end

    test "an entity no device type could manage is left out rather than listed" do
      # A household Home Assistant has hundreds of these. Offering them would
      # bury the kinds Dobby can actually do something with.
      Fake.put_entity("sensor.outdoor_humidity", %{state: "61", attributes: %{}})
      Fake.put_entity("weather.home", %{state: "sunny", attributes: %{}})

      assert {:ok, candidates} = Discovery.candidates()
      assert candidates == []
    end

    test "diagnostic entities are not proposed as household devices" do
      Fake.put_entity("sensor.receiver_temperature", %{
        state: "102",
        attributes: %{device_class: "temperature"},
        device_id: "living-room-receiver",
        entity_category: "diagnostic"
      })

      assert {:ok, []} = Discovery.candidates(type: "environment_monitor")
    end

    test "a binary_sensor is a wifi endpoint only when it reports connectivity" do
      # `binary_sensor` is HA's bucket — doors, motion, moisture and the ping
      # integration all land in it — so the domain alone is not the question.
      Fake.put_entity("binary_sensor.office_printer", %{
        state: "on",
        attributes: %{friendly_name: "Office Printer", device_class: "connectivity"}
      })

      Fake.put_entity("binary_sensor.hall_battery", %{
        state: "off",
        attributes: %{friendly_name: "Hall Battery", device_class: "battery"}
      })

      assert {:ok, candidates} = Discovery.candidates()

      assert [%{entity_id: "binary_sensor.office_printer", type: "wifi_endpoint"}] = candidates
    end

    test "a type narrows the list, and an unknown one is refused naming what exists" do
      Fake.put_entity("climate.dining_room", %{state: "heat", attributes: %{}})
      Fake.put_entity("light.porch", %{state: "off", attributes: %{}})

      assert {:ok, [%{entity_id: "light.porch"}]} = Discovery.candidates(type: "light")

      assert {:error, reason} = Discovery.candidates(type: "media_player")
      assert reason =~ "unknown device type"
      assert reason =~ "thermostat, light, speaker"
      assert reason =~ "safety_sensor, vacuum, wifi_endpoint"
    end

    test "an entity with no friendly name suggests its id and says so plainly" do
      Fake.put_entity("vacuum.roomba", %{state: "docked", attributes: %{}})

      assert {:ok, [candidate]} = Discovery.candidates(type: "vacuum")
      assert candidate.suggested_name == "vacuum.roomba"
    end
  end

  describe "where the answer comes from" do
    test "the entities are the client's own, not a fresh request anybody made" do
      # The §7 boundary in one assertion: discovery reads what the deterministic
      # layer already learned. Nothing above `Dobby.HomeAssistant` may talk to
      # Home Assistant, and a discovery read is no exception — so an entity the
      # client has never been told about cannot appear here.
      assert {:ok, []} = Discovery.candidates(type: "light")

      Fake.put_entity("light.porch", %{state: "off", attributes: %{}})

      assert {:ok, [%{entity_id: "light.porch"}]} = Discovery.candidates(type: "light")
    end

    test "attribute keys arrive as strings from a real house and as atoms from the rig" do
      # The boundary normalizes both, the way `dispatch_state_changed/4` already
      # does — a fixture and a house have to produce the same struct or agents
      # pass on the rig and fail on the wire.
      Fake.put_entity("binary_sensor.wire", %{
        state: "on",
        attributes: %{"friendly_name" => "On The Wire", "device_class" => "connectivity"}
      })

      assert {:ok, [candidate]} = Discovery.candidates(type: "wifi_endpoint")
      assert candidate.suggested_name == "On The Wire"
    end
  end

  describe "compound devices" do
    test "a doorbell is proposed once with its event, camera, and motion bindings" do
      boot_house!([])

      Fake.put_entity("event.front_door", %{
        state: "2026-08-23T12:00:00+00:00",
        attributes: %{friendly_name: "Front Door", device_class: "doorbell"},
        device_id: "front-door-device",
        platform: "ring"
      })

      Fake.put_entity("camera.front_door", %{
        state: "idle",
        attributes: %{friendly_name: "Front Door Camera"},
        device_id: "front-door-device",
        platform: "ring"
      })

      Fake.put_entity("binary_sensor.front_door_motion", %{
        state: "off",
        attributes: %{device_class: "motion"},
        device_id: "front-door-device",
        platform: "ring"
      })

      assert {:ok, [candidate]} = Discovery.candidates(type: "doorbell")

      assert candidate.bindings == %{
               "event" => "event.front_door",
               "camera" => "camera.front_door",
               "motion" => "binary_sensor.front_door_motion"
             }

      assert candidate.device_id == "front-door-device"
      assert candidate.platform == "ring"

      assert {:ok, []} = Discovery.candidates(type: "camera")
      assert {:ok, []} = Discovery.candidates(type: "occupancy_sensor")
    end

    test "readings on one HA device become one environment monitor" do
      boot_house!([])

      for {entity_id, class, state} <- [
            {"sensor.office_temperature", "temperature", "72.4"},
            {"sensor.office_humidity", "humidity", "41"}
          ] do
        Fake.put_entity(entity_id, %{
          state: state,
          attributes: %{device_class: class},
          device_id: "office-air-device"
        })
      end

      assert {:ok, [candidate]} = Discovery.candidates(type: "environment_monitor")

      assert candidate.bindings == %{
               "temperature" => "sensor.office_temperature",
               "humidity" => "sensor.office_humidity"
             }
    end
  end
end
