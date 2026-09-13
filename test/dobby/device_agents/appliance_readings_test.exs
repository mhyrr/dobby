defmodule Dobby.DeviceAgents.ApplianceReadingsTest do
  use ExUnit.Case, async: true

  alias Dobby.DeviceAgents.{Dishwasher, Dryer, Oven, Refrigerator, Washer}
  alias Jido.Agent.Directive.Emit

  test "setpoints do not manufacture a refrigerator temperature" do
    state =
      boot(Refrigerator, %{
        refrigerator_display_temperature: "sensor.fridge_display",
        refrigerator_target_temperature: "sensor.fridge_target",
        freezer_target_temperature: "sensor.freezer_target"
      })

    {state, event} = sync(Refrigerator, state, "sensor.fridge_target", "38", "°F")
    assert state.available
    assert state.readings.refrigerator_target_temperature == 38
    assert state.readings.refrigerator_display_temperature == nil
    assert state.readings.freezer_target_temperature == nil
    assert event.data.moved == []

    {state, event} = sync(Refrigerator, state, "sensor.freezer_target", "-18", "°C")
    assert state.readings.freezer_target_temperature == -18
    assert state.units.freezer_target_temperature == "°C"
    assert event.data.moved == []
    assert Refrigerator.snapshot(state).readings.refrigerator_display_temperature == nil
  end

  test "an oven outage clears its reading while the closed door remains a known fact" do
    state = boot(Oven, %{temperature: "sensor.oven", door_open: "binary_sensor.oven_door"})
    {state, _event} = sync(Oven, state, "sensor.oven", "350", "°F")
    {state, event} = sync(Oven, state, "binary_sensor.oven_door", "off")
    assert event.data.moved == []
    assert state.readings.door_open == false

    {state, event} = sync(Oven, state, "sensor.oven", "unavailable", "°F")
    assert :readings in event.data.moved
    assert state.available
    assert state.readings.temperature == nil
    refute Map.has_key?(state.units, :temperature)

    {state, _event} = sync(Oven, state, "binary_sensor.oven_door", "unknown")
    refute state.available
    assert state.readings.door_open == nil
  end

  test "malformed temperatures and missing units cannot look like measured degrees" do
    for {value, unit} <- [{"350oops", "°F"}, {"warm", "°F"}, {"350", nil}, {"350", "%"}] do
      state = boot(Oven, %{temperature: "sensor.oven"})
      {state, _event} = sync(Oven, state, "sensor.oven", value, unit)
      assert state.readings.temperature == nil
      refute state.available
    end
  end

  test "dishwasher cycle, progress, finish timestamp, and door keep their different meanings" do
    state =
      boot(Dishwasher, %{
        operation_state: "sensor.cycle",
        progress: "sensor.progress",
        finish_at: "sensor.finish",
        door_open: "sensor.door",
        remote_start_allowed: "binary_sensor.remote_start"
      })

    {state, _event} = sync(Dishwasher, state, "sensor.cycle", "run")
    {state, _event} = sync(Dishwasher, state, "sensor.progress", "42.5", "%")
    {state, _event} = sync(Dishwasher, state, "sensor.finish", "2026-09-10T18:30:00-04:00")
    {state, _event} = sync(Dishwasher, state, "sensor.door", "locked")
    {state, _event} = sync(Dishwasher, state, "binary_sensor.remote_start", "off")

    assert state.readings == %{
             operation_state: "run",
             progress: 42.5,
             finish_at: "2026-09-10T18:30:00-04:00",
             door_open: false,
             remote_start_allowed: false
           }

    {state, _event} = sync(Dishwasher, state, "sensor.progress", "101", "%")
    assert state.readings.progress == nil
    {state, _event} = sync(Dishwasher, state, "sensor.finish", "soon")
    assert state.readings.finish_at == nil
    {state, event} = sync(Dishwasher, state, "sensor.cycle", "finished")
    assert event.data.moved == [:readings]
    assert state.readings.operation_state == "finished"
  end

  test "a finish time is stated on the household's clock whatever offset it arrives on" do
    # The rig house is in America/New_York. A UTC stamp handed to the model is
    # a timezone subtraction handed to the model, and the model does not do
    # arithmetic; the house already knows its own clock.
    for sent <- [
          "2026-09-10T18:30:00-04:00",
          "2026-09-10T22:30:00Z",
          "2026-09-11T07:30:00+09:00"
        ] do
      state = boot(Dishwasher, %{finish_at: "sensor.finish"})
      {state, _event} = sync(Dishwasher, state, "sensor.finish", sent)
      assert state.readings.finish_at == "2026-09-10T18:30:00-04:00"
    end
  end

  test "a whole reading stays a whole number" do
    state = boot(Refrigerator, %{refrigerator_target_temperature: "sensor.fridge_target"})
    {state, _event} = sync(Refrigerator, state, "sensor.fridge_target", "38", "°F")

    # `38 == 38.0`, so only the term's own type catches this. The reading goes
    # to the model verbatim, and 38.0 claims a tenth of a degree the appliance
    # never reported.
    assert is_integer(state.readings.refrigerator_target_temperature)

    {state, _event} = sync(Refrigerator, state, "sensor.fridge_target", "37.5", "°F")
    assert is_float(state.readings.refrigerator_target_temperature)

    state = boot(Dishwasher, %{progress: "sensor.progress"})
    {state, _event} = sync(Dishwasher, state, "sensor.progress", "42", "%")
    assert is_integer(state.readings.progress)

    state = boot(Dryer, %{remaining_time: "sensor.remaining"})
    {state, _event} = sync(Dryer, state, "sensor.remaining", "900", "s")
    assert is_integer(state.readings.remaining_time)

    # Still the whole string or nothing: a leading whole number does not make
    # the rest of the value disappear.
    for value <- ["900s", "12:30", "38 °F"] do
      state = boot(Dryer, %{remaining_time: "sensor.remaining"})
      {state, _event} = sync(Dryer, state, "sensor.remaining", value, "s")
      assert state.readings.remaining_time == nil
    end
  end

  test "door and boolean words are read in whatever case the integration sends them" do
    for {sent, expected} <- [
          {"closed", false},
          {"Closed", false},
          {"CLOSED", false},
          {"open", true},
          {"Open", true},
          {"locked", false},
          {"Locked", false},
          {"unlocked", true},
          {"Unlocked", true},
          {"on", true},
          {"Off", false},
          {"ajar", nil}
        ] do
      state = boot(Dishwasher, %{door_open: "sensor.door"})
      {state, _event} = sync(Dishwasher, state, "sensor.door", sent)

      assert state.readings.door_open == expected,
             "#{sent} read as #{inspect(state.readings.door_open)}"
    end

    for {sent, expected} <- [{"on", true}, {"On", true}, {"off", false}, {"OFF", false}] do
      state = boot(Dishwasher, %{remote_start_allowed: "binary_sensor.remote"})
      {state, _event} = sync(Dishwasher, state, "binary_sensor.remote", sent)
      assert state.readings.remote_start_allowed == expected
    end

    # The cycle word is the manufacturer's, not a vocabulary of ours, so it is
    # the one reading that keeps the case it arrived in.
    state = boot(Dishwasher, %{operation_state: "sensor.cycle"})
    {state, _event} = sync(Dishwasher, state, "sensor.cycle", "DelayedStart")
    assert state.readings.operation_state == "DelayedStart"
  end

  test "unrelated entities and duplicate readings produce no event" do
    state = boot(Oven, %{temperature: "sensor.oven"})

    assert {:ok, %{}} =
             Oven.sync(%{entity_id: "sensor.stranger", state: "2", attributes: %{}}, state)

    {state, _event} = sync(Oven, state, "sensor.oven", "180", "°C")
    assert {_state, nil} = sync(Oven, state, "sensor.oven", "180", "°C")
  end

  test "a unit change is an observed change and a lost unit clears the value" do
    state = boot(Oven, %{temperature: "sensor.oven"})
    {state, _event} = sync(Oven, state, "sensor.oven", "180", "°C")
    {state, event} = sync(Oven, state, "sensor.oven", "356", "°F")
    assert :units in event.data.moved
    assert state.units.temperature == "°F"
    {state, _event} = sync(Oven, state, "sensor.oven", "356")
    assert state.readings.temperature == nil
    refute state.available
  end

  test "one sensor cannot supply both a measurement and a setpoint" do
    device = %Dobby.Home.Device{
      id: "oven:test",
      name: "oven",
      agent_module: Oven,
      bindings: %{temperature: "sensor.oven", target_temperature: "sensor.oven"},
      settings: %{}
    }

    assert {:error, "each appliance reading must bind a different entity"} =
             Oven.validate_device(device)
  end

  test "laundry remaining time preserves units and never decides that the cycle finished" do
    for module <- [Washer, Dryer],
        {value, unit, expected} <- [{"90", "s", 90.0}, {"1.5", "min", 1.5}, {"0", "h", 0.0}] do
      state = boot(module, %{operation_state: "sensor.cycle", remaining_time: "sensor.remaining"})
      {state, _event} = sync(module, state, "sensor.cycle", "running")
      {state, event} = sync(module, state, "sensor.remaining", value, unit)
      assert state.units.remaining_time == unit
      assert state.readings.remaining_time == expected
      assert state.readings.operation_state == "running"
      assert event.data.moved == []
      assert module.scheduled_actions() == %{}
    end
  end

  test "unusable laundry duration readings clear the value and unit without losing cycle state" do
    for module <- [Washer, Dryer],
        {value, unit} <- [
          {"-1", "min"},
          {"01:30", "min"},
          {"soon", "s"},
          {"30", nil},
          {"30", "%"},
          {"unavailable", "min"}
        ] do
      state = boot(module, %{operation_state: "sensor.cycle", remaining_time: "sensor.remaining"})
      {state, _event} = sync(module, state, "sensor.cycle", "running")
      {state, _event} = sync(module, state, "sensor.remaining", "12", "min")
      {state, event} = sync(module, state, "sensor.remaining", value, unit)
      assert state.available
      assert state.readings.remaining_time == nil
      refute Map.has_key?(state.units, :remaining_time)
      assert :readings in event.data.moved
      assert state.readings.operation_state == "running"
    end
  end

  defp boot(module, bindings) do
    device = %Dobby.Home.Device{
      id: "#{module.config_type()}:test",
      name: "test appliance",
      agent_module: module,
      bindings: bindings,
      settings: %{}
    }

    module.new(id: device.id, state: module.initial_state(device)).state
  end

  defp sync(module, state, entity, value, unit \\ nil) do
    params = %{entity_id: entity, state: value, attributes: %{"unit_of_measurement" => unit}}
    # Exercise Jido's schema too: HA attribute keys arrive as strings.
    [{"ha.state_changed", action}] = module.signal_routes()

    case Jido.Exec.run(action, params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{signal: signal}]} -> {Map.merge(state, next), signal}
    end
  end
end
