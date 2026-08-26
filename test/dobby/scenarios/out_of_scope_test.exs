defmodule Dobby.Scenarios.OutOfScopeTest do
  @moduledoc """
  Things the house cannot do: "make the family room cozy" when Dobby has no
  concept of rooms, and "turn the Yellowstone playlist on" when it has no
  media player at all.

  ## What the replay tier can and cannot prove here

  Very little, honestly, and saying so is the point. Scripting the model to
  decline proves only that a turn with no tool call leaves the house
  untouched. Whether a *real* model declines — rather than confidently
  aiming a thermostat at a request about a playlist — is an eval-tier
  question, and these same utterances run there.

  What this file *can* prove structurally is stronger than behavior: the
  model is never offered a tool it could misuse, and the house block it reads
  never mentions a room or a playlist. Declining isn't good judgment on the
  model's part; it's the only move available.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.{DobbyAgent, Utterance}
  alias Dobby.DobbyAgent.RequestTransformer

  @climate "climate.main_floor"

  setup do
    boot_house!([
      thermostat_device("thermostat:main", "main thermostat", entity: @climate),
      light_device("light:living_room", "living room light", entity: "light.living_room"),
      vacuum_device("vacuum:robo", "robot vacuum", entity: "vacuum.robo"),
      wifi_device("wifi:kitchen_tv", "kitchen TV", "binary_sensor.kitchen_tv"),
      wifi_device("wifi:office_printer", "office printer", "binary_sensor.office_printer")
    ])

    seed_house(%{
      @climate => thermostat_entity(current: 68, target: 68),
      "binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}},
      "binary_sensor.office_printer" => %{state: "off", attributes: %{}}
    })

    Trace.reset()
    :ok
  end

  describe "a place the house does not model" do
    test "asking about the family room actuates nothing" do
      utterance = Utterance.new("greg", "Dobby, make the family room cozy")

      script =
        expect_react do
          user(Utterance.to_message(utterance))

          answer(
            "I don't have anything set up for the family room — I've only got the main thermostat. Want me to warm that up?"
          )
        end

      assert {:ok, reply} = DobbyAgent.say(utterance, react_opts(script))

      assert reply =~ "family room"
      assert Trace.tool_calls() == []
      assert Trace.ha_calls() == []
    end

    test "rooms appear nowhere in what the model is told exists" do
      # Dobby has devices, not places. Design §11 defers room and space agents
      # deliberately, so "the family room" resolves to nothing — and the model
      # is never given a reason to believe otherwise. A device may be *named*
      # after a room ("living room light"); a name is opaque, and the
      # structural assertion is that every line of the house is a device off
      # the manifest, with nothing else to hang a place on.
      house = RequestTransformer.render(world_model())

      refute house =~ "family room"
      assert house =~ "main thermostat"

      device_ids = Enum.map(Dobby.Home.devices(), & &1.id)

      house
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "- "))
      |> Enum.each(fn line ->
        assert Enum.any?(device_ids, &String.starts_with?(line, "- #{&1}"))
      end)
    end
  end

  describe "a capability the house does not have" do
    test "asking for a playlist actuates nothing" do
      utterance = Utterance.new("greg", "Dobby, turn the Yellowstone playlist on")

      script =
        expect_react do
          user(Utterance.to_message(utterance))
          answer("I can't play music — I've only got the thermostat and a couple of endpoints.")
        end

      assert {:ok, _reply} = DobbyAgent.say(utterance, react_opts(script))

      assert Trace.tool_calls() == []
      assert Trace.ha_calls() == []
    end

    test "there is no media tool to misuse, which is the actual guarantee" do
      # This is the structural assertion, and it is worth more than the
      # behavioral one above: the model declining is not a judgment call it
      # got right, it is the only branch that exists.
      tool_names = Enum.map(Dobby.Home.tools(), & &1.name())

      # Device tools come from the manifest; the schedule tools and the config
      # three belong to the house and are offered whatever is plugged in. Every
      # half is pinned, because "what can Dobby do at all" is exactly the list
      # this asserts — and a tool arriving here unnoticed is the failure mode.
      #
      # Note what the config three can and cannot do. They can describe a
      # device; they cannot invent a media player, because a type not in
      # `Dobby.HomeConfig.Types` is refused by the same closure the file is
      # held to. Adding a way to change the house did not add a way past it.
      assert tool_names == [
               "thermostat_get_status",
               "thermostat_set_temperature",
               "light_get_status",
               "light_turn_on",
               "light_turn_off",
               "light_set_brightness",
               "vacuum_get_status",
               "vacuum_start",
               "vacuum_dock",
               "wifi_get_status",
               "create_schedule",
               "list_schedules",
               "set_schedule_enabled",
               "delete_schedule",
               "discover_entities",
               "propose_device",
               "confirm_device"
             ]

      refute Enum.any?(tool_names, &(&1 =~ ~r/play|media|music|speaker|sonos/i))
    end

    test "the config tools cannot name a device type Dobby does not have" do
      # The same closure, reached the other way: a model that answered
      # "media_player" to propose_device is refused by the registry rather than
      # by anybody's manners.
      assert {:error, reason} =
               Dobby.Tools.ProposeDevice.on_before_validate_params(%{
                 type: "media_player",
                 settings: %{}
               })

      assert reason =~ "unknown device type"
      assert reason =~ "thermostat"
    end

    test "an invented device id is refused by the tool, not by the model's manners" do
      # Even if a model did try, the roster check is what stops it — and the
      # refusal goes back as an observation it must account for in its reply.
      assert {:error, error} =
               Jido.Exec.run(Dobby.Tools.ThermostatSetTemperature, %{
                 device: "media_player:living_room",
                 temperature_f: 70
               })

      assert error.message =~ "unknown device"
      assert Trace.ha_calls() == []
    end
  end

  defp world_model do
    agent_state(DobbyAgent.id()) |> Map.get(:world_model) || %{}
  end

  defp wifi_device(id, name, entity_id) do
    %{
      id: id,
      name: name,
      aliases: [],
      agent_module: Dobby.DeviceAgents.WifiEndpoint,
      network: :home_wifi,
      ha_integration: :ping,
      bindings: %{connectivity: entity_id},
      settings: %{}
    }
  end
end
