defmodule Dobby.DeviceAgents.WaterHeaterTest do
  use Dobby.RigCase, async: false
  import Dobby.DeviceAgentContract
  alias Dobby.DeviceAgents.WaterHeater
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.WaterHeater,
    bindings: %{water_heater: "water_heater.contract"},
    entity: [entity_id: "water_heater.contract"],
    arrivals: [
      {%{result: :accepted, action: :set_temperature, temperature_f: 120},
       %{available: true, target_temperature_f: 120},
       %{available: true, target_temperature_f: 110}},
      {%{result: :accepted, action: :set_mode, mode: "eco"}, %{available: true, mode: "eco"},
       %{available: true, mode: "gas"}},
      {%{result: :accepted, action: :set_away_mode, away_mode: false},
       %{available: true, away_mode: false}, %{available: true, away_mode: true}},
      {%{result: :accepted, action: :set_power, power: :off}, %{available: true, power: :off},
       %{available: true, power: :on}}
    ]
  )

  test "manifest validates native domain, unit and narrowing bounds" do
    assert :ok = WaterHeater.validate_device(device())

    for settings <- [
          %{temperature_unit: "F"},
          %{min_temperature_f: 130, max_temperature_f: 120},
          %{unknown: true}
        ] do
      assert {:error, _} = WaterHeater.validate_device(%{device() | settings: settings})
    end

    assert {:error, _} =
             WaterHeater.validate_device(%{device() | bindings: %{water_heater: "climate.test"}})
  end

  test "native temperatures require known units, convert deterministically, and obey both bounds" do
    for {unit, current, target, low, high} <- [
          {"°F", 100, 122, 90, 150},
          {"°C", 38, 50, 30, 65},
          {"K", 311, 323.15, 303.15, 338.15}
        ] do
      {state, _} =
        sync(
          boot(%{temperature_unit: unit, max_temperature_f: 125}),
          "eco",
          Map.merge(attrs(), %{
            "current_temperature" => current,
            "temperature" => target,
            "min_temp" => low,
            "max_temp" => high
          })
        )

      assert_in_delta state.target_temperature_f, 122, 0.001

      assert {:ok, update,
              [%HACall{domain: "water_heater", service: "set_temperature", data: data}]} =
               WaterHeater.SetTemperature.run(%{temperature_f: 120, ref: "cmd"}, %{state: state})

      assert Map.keys(update) == [:last_command]
      assert_in_delta WaterHeater.to_f(data.temperature, unit), 120, 0.001
      reject(WaterHeater.SetTemperature.run(%{temperature_f: 126, ref: "cmd"}, %{state: state}))
      reject(WaterHeater.SetTemperature.run(%{temperature_f: 80, ref: "cmd"}, %{state: state}))
    end

    for attributes <- [attrs(), Map.put(attrs(), "unit_of_measurement", "bad")] do
      {state, _} = sync(boot(), "eco", attributes)
      assert is_nil(state.target_temperature_f)
      reject(WaterHeater.SetTemperature.run(%{temperature_f: 120, ref: "cmd"}, %{state: state}))
    end

    {state, _} =
      sync(boot(%{temperature_unit: "°F"}), "eco", Map.put(attrs(), "unit_of_measurement", "°C"))

    assert state.temperature_unit == "°C"
  end

  test "all controls refuse before sync and when their capability is absent" do
    commands = [
      {WaterHeater.SetTemperature, %{temperature_f: 120}},
      {WaterHeater.SetMode, %{mode: "eco"}},
      {WaterHeater.SetAwayMode, %{away_mode: true}},
      {WaterHeater.SetPower, %{power: :on}}
    ]

    {unsupported, _} =
      sync(boot(%{temperature_unit: "°F"}), "eco", Map.put(attrs(), "supported_features", 0))

    for state <- [boot(), unsupported], {action, args} <- commands do
      reject(action.run(Map.put(args, :ref, "cmd"), %{state: state}))
    end

    {state, _} = sync(boot(%{temperature_unit: "°F"}), "eco", attrs())
    reject(WaterHeater.SetMode.run(%{mode: "invented", ref: "cmd"}, %{state: state}))
    {bad_range, _} = sync(state, "eco", Map.delete(attrs(), "min_temp"))
    reject(WaterHeater.SetTemperature.run(%{temperature_f: 120, ref: "cmd"}, %{state: bad_range}))
  end

  test "observations distinguish first report, echo, a manual change and unavailable stale attributes" do
    {state, %Emit{signal: first}} = sync(boot(%{temperature_unit: "°F"}), "eco", attrs())
    assert first.data.moved == []

    {:ok, command, [_]} =
      WaterHeater.SetTemperature.run(%{temperature_f: 120, ref: "cmd"}, %{state: state})

    {arrived, %Emit{signal: echo}} =
      sync(Map.merge(state, command), "eco", Map.put(attrs(), "temperature", 120))

    assert echo.data.commanded?
    {_hand, %Emit{signal: hand}} = sync(arrived, "eco", Map.put(attrs(), "temperature", 115))
    refute hand.data.commanded?

    {_manual_mode, %Emit{signal: mode_changed}} =
      sync(arrived, "gas", Map.put(attrs(), "temperature", 120))

    refute mode_changed.data.commanded?

    {lost, %Emit{signal: loss}} =
      sync(arrived, "unavailable", Map.put(attrs(), "temperature", 120))

    refute loss.data.commanded?
    refute WaterHeater.command_arrived?(command.last_command, WaterHeater.snapshot(lost))
    assert is_nil(lost.target_temperature_f)
    assert is_nil(lost.capabilities.supports_temperature)

    assert {:ok, %{}} =
             WaterHeater.SyncState.run(%{entity_id: "water_heater.other"}, %{state: state})
  end

  test "live tools send the native services and match each reported command" do
    boot_house!([Map.from_struct(device())])
    seed_house(%{"water_heater.test" => %{state: "eco", attributes: attrs()}})

    assert {:ok, %{target_temperature_f: 110, current_temperature_f: 100}} =
             Jido.Exec.run(Dobby.Tools.WaterHeaterGetStatus, %{device: "water_heater:test"})

    for value <- [120, 120.0, "120"] do
      assert {:ok, %{accepted: true, target_temperature_f: 120.0}} =
               Jido.Exec.run(Dobby.Tools.WaterHeaterSetTemperature, %{
                 device: "water_heater:test",
                 temperature_f: value
               })

      assert_receive {:ha_call,
                      %HACall{
                        domain: "water_heater",
                        service: "set_temperature",
                        data: %{temperature: 120.0}
                      }},
                     2_000
    end

    assert_receive %Jido.Signal{
                     type: "dobby.device.state_changed",
                     data: %{
                       snapshot: %{id: "water_heater:test", target_temperature_f: 120.0},
                       commanded?: true
                     }
                   },
                   2_000

    for {tool, args, service, reading, expected} <- [
          {Dobby.Tools.WaterHeaterSetMode, %{mode: "gas"}, "set_operation_mode", :mode, "gas"},
          {Dobby.Tools.WaterHeaterSetAwayMode, %{away_mode: true}, "set_away_mode", :away_mode,
           true},
          {Dobby.Tools.WaterHeaterTurnOff, %{}, "turn_off", :power, :off},
          {Dobby.Tools.WaterHeaterTurnOn, %{}, "turn_on", :power, :on}
        ] do
      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(tool, Map.put(args, :device, "water_heater:test"))

      assert_receive {:ha_call, %HACall{service: ^service}}, 2_000

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{
                         snapshot: %{^reading => ^expected, id: "water_heater:test"} = snapshot,
                         commanded?: true
                       }
                     },
                     2_000

      assert snapshot[reading] == expected
    end

    assert {:error, _} =
             Jido.Exec.run(Dobby.Tools.WaterHeaterSetTemperature, %{
               device: "water_heater:test",
               temperature_f: "120junk"
             })

    assert {:error, _} =
             Jido.Exec.run(Dobby.Tools.HumidifierGetStatus, %{device: "water_heater:test"})
  end

  defp reject(result), do: assert({:ok, %{last_command: %{result: {:rejected, _}}}} = result)

  defp device,
    do: %Dobby.Home.Device{
      id: "water_heater:test",
      name: "Hot water",
      agent_module: WaterHeater,
      bindings: %{water_heater: "water_heater.test"},
      settings: %{temperature_unit: "°F", max_temperature_f: 125}
    }

  defp boot(settings \\ %{}) do
    d = %{device() | settings: settings}
    WaterHeater.new(id: d.id, state: WaterHeater.initial_state(d)).state
  end

  defp attrs,
    do: %{
      "current_temperature" => 100,
      "temperature" => 110,
      "min_temp" => 90,
      "max_temp" => 150,
      "supported_features" => 15,
      "operation_list" => ["eco", "gas", "off"],
      "away_mode" => "off"
    }

  defp sync(state, report, attributes) do
    case WaterHeater.SyncState.run(
           %{entity_id: state.entity_id, state: report, attributes: attributes},
           %{state: state}
         ) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [emit]} -> {Map.merge(state, next), emit}
    end
  end
end
