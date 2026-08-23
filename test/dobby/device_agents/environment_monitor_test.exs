defmodule Dobby.DeviceAgents.EnvironmentMonitorTest do
  @moduledoc """
  The deterministic layer for the environment monitor.

  The judgment worth pinning is per-cell movement. Many sensors live inside
  one `readings` map, and judging the whole map would make the second
  sensor's first report read as the house moving — the boot sequence landing
  in the log, one sensor at a time.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.EnvironmentMonitor
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.EnvironmentMonitor,
    bindings: %{temperature: "sensor.contract_temperature"},
    entity: [entity_id: "sensor.contract_temperature", device_class: "temperature"],
    related: [[entity_id: "sensor.contract_temperature", device_class: "temperature"]]
  )

  test "each sensor's first report is arrival, and only a change to a known cell moves" do
    state = booted_state()

    {state, %Emit{signal: first}} = sync(state, "sensor.test_temperature", "72.4", "°F")
    assert :readings in first.data.changed
    assert first.data.moved == []

    # The humidity sensor reporting for the first time must not ride the
    # temperature cell's existing value into `moved`.
    {state, %Emit{signal: second_sensor}} = sync(state, "sensor.test_humidity", "41", "%")
    assert :readings in second_sensor.data.changed
    assert second_sensor.data.moved == []

    {_state, %Emit{signal: warmed}} = sync(state, "sensor.test_temperature", "73.1", "°F")
    assert warmed.data.moved == [:readings]
    assert warmed.data.snapshot.readings == %{temperature: 73.1, humidity: 41.0}
  end

  test "a reading HA cannot number is nil, and an entity nobody bound updates nothing" do
    state = booted_state()

    {state, _emit} = sync(state, "sensor.test_temperature", "unknown", nil)
    assert state.readings == %{temperature: nil}
    refute state.available

    assert {:ok, %{}} =
             EnvironmentMonitor.SyncState.run(
               %{entity_id: "sensor.stranger", state: "5", attributes: %{}},
               %{state: state}
             )
  end

  test "a monitor with no reading bindings is not a monitor" do
    device = %Dobby.Home.Device{
      id: "monitor:empty",
      name: "empty monitor",
      agent_module: EnvironmentMonitor,
      bindings: %{},
      settings: %{}
    }

    assert {:error, reason} = EnvironmentMonitor.validate_device(device)
    assert reason =~ "at least one reading"
  end

  test "readings are observed, never done" do
    for attribute <- [:readings, :units, :available] do
      refute EnvironmentMonitor.intervention?(attribute)
    end

    assert EnvironmentMonitor.scheduled_actions() == %{}
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "monitor:test",
      name: "test monitor",
      agent_module: EnvironmentMonitor,
      bindings: %{
        temperature: "sensor.test_temperature",
        humidity: "sensor.test_humidity"
      },
      settings: %{}
    }

    EnvironmentMonitor.new(id: device.id, state: EnvironmentMonitor.initial_state(device)).state
  end

  defp sync(state, entity_id, value, unit) do
    attributes = if unit, do: %{"unit_of_measurement" => unit}, else: %{}
    params = %{entity_id: entity_id, state: value, attributes: attributes}

    case EnvironmentMonitor.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
