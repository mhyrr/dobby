defmodule Dobby.DeviceAgents.ThermostatTest do
  @moduledoc """
  The deterministic layer, with no model anywhere near it.

  Design §8 calls this path load-bearing: it is the test surface for
  everything below the LLM and the fallback when the model is unavailable. If
  these fail, nothing above them is worth debugging.
  """

  use Dobby.RigCase, async: false

  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Thermostat,
    bindings: %{climate: "climate.contract"},
    settings: %{min_temperature_f: 60, max_temperature_f: 76},
    entity: [entity_id: "climate.contract"]
  )

  alias Dobby.Tools.{ThermostatGetStatus, ThermostatSetTemperature}

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  describe "capability discovery" do
    test "reads the device's envelope from its HA entity rather than the manifest" do
      seed_house(%{@entity => thermostat_entity(min_temp: 55, max_temp: 85)})

      state = agent_state(@thermostat)

      assert state.available
      assert state.capabilities.min_temperature_f == 55
      assert state.capabilities.max_temperature_f == 85
      assert state.current_temperature_f == 68
      assert state.hvac_mode == :heat
    end

    test "the accepted range is the intersection of hardware and household policy" do
      # Hardware allows 50-90. The rig manifest narrows to 60-76.
      seed_house(%{@entity => thermostat_entity(min_temp: 50, max_temp: 90)})
      assert {60, 76} == Dobby.DeviceAgents.Thermostat.accepted_range(agent_state(@thermostat))

      # Hardware narrower than policy on the top end wins.
      Fake.inject_state_changed(
        @entity,
        thermostat_entity(min_temp: 50, max_temp: 72, target: 69)
      )

      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {60, 72} == Dobby.DeviceAgents.Thermostat.accepted_range(agent_state(@thermostat))
    end
  end

  describe "set_temperature" do
    setup do
      seed_house(%{@entity => thermostat_entity(target: 68)})
      :ok
    end

    test "an allowed setpoint reaches HA as one service call" do
      assert {:ok, result} =
               Jido.Exec.run(ThermostatSetTemperature, %{device: @thermostat, temperature_f: 70})

      assert result.accepted
      assert result.target_temperature_f == 70.0

      assert_receive {:ha_call,
                      %HACall{
                        domain: "climate",
                        service: "set_temperature",
                        entity_id: @entity,
                        data: %{temperature: 70.0}
                      }},
                     2_000

      assert [%HACall{service: "set_temperature"}] = Fake.trace()
    end

    test "agent state follows the physical confirm loop, not the command" do
      # Before HA reports back, the agent still believes the old setpoint —
      # this is the property the system prompt's write-acknowledgment rule
      # exists to protect.
      assert {:ok, _result} =
               Jido.Exec.run(ThermostatSetTemperature, %{device: @thermostat, temperature_f: 70})

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.target_temperature_f == 70.0
      assert agent_state(@thermostat).target_temperature_f == 70.0
    end

    test "a setpoint outside household policy is refused with a reason, and never reaches HA" do
      assert {:ok, result} =
               Jido.Exec.run(ThermostatSetTemperature, %{device: @thermostat, temperature_f: 82})

      refute result.accepted
      assert result.reason =~ "above"
      assert result.reason =~ "76"

      assert Fake.trace() == []
      refute_receive {:ha_call, _}, 200
    end

    test "an unavailable thermostat is refused rather than commanded blind" do
      Fake.inject_state_changed(@entity, %{state: "unavailable", attributes: %{}})
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {:ok, result} =
               Jido.Exec.run(ThermostatSetTemperature, %{device: @thermostat, temperature_f: 70})

      refute result.accepted
      assert result.reason =~ "unavailable"
      assert Fake.trace() == []
    end
  end

  describe "get_status" do
    test "answers from agent state with no HA round trip" do
      seed_house(%{@entity => thermostat_entity(current: 66, target: 68)})

      assert {:ok, status} = Jido.Exec.run(ThermostatGetStatus, %{device: @thermostat})

      assert status.device == @thermostat
      assert status.name == "main thermostat"
      assert status.current_temperature_f == 66
      assert status.target_temperature_f == 68
      assert status.available

      assert Fake.trace() == []
    end
  end

  describe "the closed roster" do
    setup do
      seed_house(%{@entity => thermostat_entity()})
      :ok
    end

    test "a device this house does not have is refused, and the error names what it does have" do
      assert {:error, error} =
               Jido.Exec.run(ThermostatSetTemperature, %{
                 device: "thermostat:guest",
                 temperature_f: 70
               })

      # Jido.Exec wraps a tool's refusal in an error struct — this is the shape
      # that flows back to the model as an observation it has to account for,
      # so it is the shape worth asserting.
      assert error.message =~ "unknown device"
      assert error.message =~ @thermostat
      assert Fake.trace() == []
    end
  end
end
