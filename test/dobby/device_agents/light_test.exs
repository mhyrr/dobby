defmodule Dobby.DeviceAgents.LightTest do
  @moduledoc """
  The deterministic layer for lights, with no model anywhere near it.

  Same architecture as the thermostat suite: commands go out as `HACall`s,
  FakeHA moves the world, and agent state changes only when the world comes
  back. Dimming rides on discovery — the tests that matter here are the ones
  where the hardware said no.
  """

  use Dobby.RigCase, async: false

  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Light,
    bindings: %{light: "light.contract"},
    entity: [entity_id: "light.contract"]
  )

  alias Dobby.Tools.{LightGetStatus, LightSetBrightness, LightTurnOff, LightTurnOn}

  @light "light:living_room"
  @entity "light.living_room"

  describe "capability discovery" do
    test "a bulb with color modes beyond onoff dims" do
      seed_house(%{@entity => light_entity(color_modes: ["color_temp", "hs"])})

      state = agent_state(@light)

      assert state.available
      assert state.power == :on
      assert state.brightness_percent == 50
      assert Dobby.DeviceAgents.Light.dimmable?(state)
    end

    test "a switch-only bulb does not" do
      seed_house(%{@entity => light_entity(color_modes: ["onoff"], brightness: nil)})

      refute Dobby.DeviceAgents.Light.dimmable?(agent_state(@light))
    end
  end

  describe "turn on and off" do
    setup do
      seed_house(%{@entity => light_entity(state: "off")})
      :ok
    end

    test "turning on reaches HA as one service call, and state follows the confirm loop" do
      assert {:ok, result} = Jido.Exec.run(LightTurnOn, %{device: @light})
      assert result.accepted

      assert_receive {:ha_call, %HACall{domain: "light", service: "turn_on", entity_id: @entity}},
                     2_000

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.power == :on
      assert agent_state(@light).power == :on
    end

    test "turning off nulls the brightness with the power" do
      Fake.inject_state_changed(@entity, light_entity(state: "on", brightness: 255))
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {:ok, result} = Jido.Exec.run(LightTurnOff, %{device: @light})
      assert result.accepted

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.power == :off
      assert snapshot.brightness_percent == nil
    end

    test "an unavailable light is refused rather than commanded blind" do
      Fake.inject_state_changed(@entity, %{state: "unavailable", attributes: %{}})
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {:ok, result} = Jido.Exec.run(LightTurnOn, %{device: @light})

      refute result.accepted
      assert result.reason =~ "unavailable"
      assert Fake.trace() == []
    end
  end

  describe "set_brightness" do
    test "an allowed brightness reaches HA as light.turn_on with brightness_pct" do
      seed_house(%{@entity => light_entity()})

      assert {:ok, result} =
               Jido.Exec.run(LightSetBrightness, %{device: @light, brightness_percent: 60})

      assert result.accepted

      assert_receive {:ha_call,
                      %HACall{
                        domain: "light",
                        service: "turn_on",
                        entity_id: @entity,
                        data: %{brightness_pct: 60}
                      }},
                     2_000

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.brightness_percent == 60
      assert agent_state(@light).brightness_percent == 60
    end

    test "a bulb that cannot dim refuses with the reason, and never reaches HA" do
      seed_house(%{@entity => light_entity(color_modes: ["onoff"], brightness: nil)})

      assert {:ok, result} =
               Jido.Exec.run(LightSetBrightness, %{device: @light, brightness_percent: 60})

      refute result.accepted
      assert result.reason =~ "does not support brightness"
      assert Fake.trace() == []
      refute_receive {:ha_call, _call}, 200
    end

    test "zero percent is refused toward turn_off rather than guessed at" do
      seed_house(%{@entity => light_entity()})

      assert {:ok, result} =
               Jido.Exec.run(LightSetBrightness, %{device: @light, brightness_percent: 0})

      refute result.accepted
      assert result.reason =~ "turn it off"
      assert Fake.trace() == []
    end
  end

  describe "get_status" do
    test "answers from agent state with no HA round trip" do
      seed_house(%{@entity => light_entity(brightness: 204)})

      assert {:ok, status} = Jido.Exec.run(LightGetStatus, %{device: @light})

      assert status.device == @light
      assert status.name == "living room light"
      assert status.power == :on
      assert status.brightness_percent == 80
      assert status.dimmable
      assert status.available

      assert Fake.trace() == []
    end
  end
end
