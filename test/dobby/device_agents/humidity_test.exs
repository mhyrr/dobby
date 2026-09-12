defmodule Dobby.DeviceAgents.HumidityTest do
  @moduledoc "Both semantic humidity types must obey the same live HA protocol."
  use Dobby.RigCase, async: false

  alias Dobby.DeviceAgents.{Humidity, Humidifier, Dehumidifier}
  alias Dobby.HomeAssistant.Entity
  alias Jido.Agent.Directive.Emit

  for {module, type, other, tools} <- [
        {Humidifier, :humidifier, "dehumidifier",
         [
           Dobby.Tools.HumidifierGetStatus,
           Dobby.Tools.HumidifierSetHumidity,
           Dobby.Tools.HumidifierSetMode,
           Dobby.Tools.HumidifierTurnOn,
           Dobby.Tools.HumidifierTurnOff
         ]},
        {Dehumidifier, :dehumidifier, "humidifier",
         [
           Dobby.Tools.DehumidifierGetStatus,
           Dobby.Tools.DehumidifierSetHumidity,
           Dobby.Tools.DehumidifierSetMode,
           Dobby.Tools.DehumidifierTurnOn,
           Dobby.Tools.DehumidifierTurnOff
         ]}
      ] do
    @module module
    @device_type type
    @other other
    @tools tools

    test "#{type} discovers only its exact HA class and validates its manifest" do
      assert @module.matches_entity?(%Entity{
               entity_id: "humidifier.test",
               device_class: to_string(@device_type)
             })

      refute @module.matches_entity?(%Entity{entity_id: "humidifier.test", device_class: @other})
      refute @module.matches_entity?(%Entity{entity_id: "humidifier.test"})

      refute @module.matches_entity?(%Entity{
               entity_id: "switch.test",
               device_class: to_string(@device_type)
             })

      assert :ok =
               @module.validate_device(
                 device(@module, @device_type, %{
                   min_humidity_percent: 35,
                   max_humidity_percent: 60
                 })
               )

      for settings <- [
            %{min_humidity_percent: 65, max_humidity_percent: 60},
            %{min_humidity_percent: -1},
            %{max_humidity_percent: "60"},
            %{anything: true}
          ] do
        assert {:error, _} = @module.validate_device(device(@module, @device_type, settings))
      end

      assert {:error, _} =
               @module.validate_device(%{
                 device(@module, @device_type)
                 | bindings: %{humidifier: "switch.test"}
               })
    end

    test "#{type} reports HA readings and accepts model integer, float and numeric string targets" do
      boot_house!([Map.from_struct(device(@module, @device_type))])
      seed_house(%{"humidifier.test" => entity(@device_type)})
      [status_tool, humidity_tool, _mode, _on, _off] = @tools
      id = "#{@device_type}:test"
      assert {:ok, status} = Jido.Exec.run(status_tool, %{device: id})
      assert status.type == @device_type
      assert status.current_humidity_percent == 42.5
      assert status.target_humidity_percent == 45
      assert status.units.current_humidity_percent == "%"
      assert status.capabilities.available_modes == ["auto", "sleep"]

      for target <- [50, 50.0, "50", "50.0"] do
        assert {:ok, %{accepted: true, target_humidity_percent: 50}} =
                 Jido.Exec.run(humidity_tool, %{device: id, target_humidity_percent: target})

        assert_receive {:ha_call,
                        %HACall{
                          domain: "humidifier",
                          service: "set_humidity",
                          entity_id: "humidifier.test",
                          data: %{humidity: 50}
                        }},
                       2_000
      end

      for target <- ["50%", "50oops", 50.4, "50.4"] do
        assert {:error, _} =
                 Jido.Exec.run(humidity_tool, %{device: id, target_humidity_percent: target})
      end

      assert length(Fake.trace()) == 4
      settle_watcher!()
    end

    test "#{type} live tools use power and advertised mode services and reject wrong roster types" do
      boot_house!([Map.from_struct(device(@module, @device_type))])
      seed_house(%{"humidifier.test" => entity(@device_type)})
      [_status, _humidity, mode_tool, on_tool, off_tool] = @tools
      id = "#{@device_type}:test"

      for {tool, args, service, data} <- [
            {on_tool, %{}, "turn_on", %{}},
            {off_tool, %{}, "turn_off", %{}},
            {mode_tool, %{mode: "sleep"}, "set_mode", %{mode: "sleep"}}
          ] do
        assert {:ok, %{accepted: true}} = Jido.Exec.run(tool, Map.put(args, :device, id))

        assert_receive {:ha_call, %HACall{domain: "humidifier", service: ^service, data: ^data}},
                       2_000
      end

      assert {:ok, %{accepted: false}} = Jido.Exec.run(mode_tool, %{device: id, mode: "invented"})

      other_tool =
        if @device_type == :humidifier,
          do: Dobby.Tools.DehumidifierGetStatus,
          else: Dobby.Tools.HumidifierGetStatus

      assert {:error, wrong} = other_tool.run(%{device: id}, %{})
      assert wrong =~ "is not a"
      assert {:error, missing} = other_tool.run(%{device: "missing"}, %{})
      assert missing =~ "unknown device"
      assert length(Fake.trace()) == 3
      settle_watcher!()
    end

    test "#{type} refuses commands before sync, on unavailable reports, and on an incompatible class" do
      boot = state(@module, @device_type)
      assert_rejected(Humidity.set_power(%{power: :on, ref: "boot"}, boot), "unavailable")

      for report <- [nil, "unavailable", "unknown", "nonsense"] do
        {next, _} = sync(boot, report, attributes(@device_type))

        assert_rejected(
          Humidity.set_humidity(%{target_humidity_percent: 45, ref: "cmd"}, next),
          "unavailable"
        )
      end

      for class <- [@other, nil] do
        {next, _} = sync(boot, "on", Map.put(attributes(@device_type), "device_class", class))
        assert_rejected(Humidity.set_power(%{power: :off, ref: "cmd"}, next), "device class")
      end
    end

    test "#{type} narrows the reported range, honors steps, and refuses unknown capabilities" do
      boot = state(@module, @device_type, %{min_humidity_percent: 35, max_humidity_percent: 55})
      {next, _} = sync(boot, "on", attributes(@device_type))

      for target <- [25, 30, 60, 90, 36] do
        assert {:ok, %{last_command: %{result: {:rejected, _}}}} =
                 Humidity.set_humidity(%{target_humidity_percent: target, ref: "cmd"}, next)
      end

      assert {:ok, update, [%HACall{data: %{humidity: 50}}]} =
               Humidity.set_humidity(%{target_humidity_percent: 50, ref: "cmd"}, next)

      assert Map.keys(update) == [:last_command]
      assert next.target_humidity_percent == 45

      for attrs <- [
            Map.delete(attributes(@device_type), "min_humidity"),
            Map.put(attributes(@device_type), "max_humidity", 20)
          ] do
        {unknown, _} = sync(boot, "on", attrs)

        assert_rejected(
          Humidity.set_humidity(%{target_humidity_percent: 50, ref: "cmd"}, unknown),
          "range"
        )
      end

      for attrs <- [
            Map.put(attributes(@device_type), "supported_features", 0),
            Map.delete(attributes(@device_type), "supported_features"),
            Map.put(attributes(@device_type), "available_modes", nil),
            Map.put(attributes(@device_type), "available_modes", ["sleep", 1])
          ] do
        {unknown, _} = sync(boot, "on", attrs)
        assert_rejected(Humidity.set_mode(%{mode: "sleep", ref: "cmd"}, unknown), "advertises")
      end
    end

    test "#{type} snapshots distinguish first report, changes, command echoes, and loss of knowledge" do
      boot = state(@module, @device_type)
      {first, %Emit{signal: learned}} = sync(boot, "on", attributes(@device_type))
      assert learned.data.moved == []
      assert :capabilities in learned.data.changed

      {:ok, command, [_]} =
        Humidity.set_humidity(%{target_humidity_percent: 50, ref: "cmd"}, first)

      {arrived, %Emit{signal: echo}} =
        sync(Map.merge(first, command), "on", Map.put(attributes(@device_type), "humidity", 50))

      assert echo.data.commanded?
      assert :target_humidity_percent in echo.data.moved

      {_manual_mode, %Emit{signal: mode_changed}} =
        sync(
          arrived,
          "on",
          attributes(@device_type) |> Map.put("humidity", 50) |> Map.put("mode", "sleep")
        )

      refute mode_changed.data.commanded?

      {hand, %Emit{signal: changed}} =
        sync(arrived, "on", Map.put(attributes(@device_type), "humidity", 55))

      refute changed.data.commanded?
      {lost, %Emit{signal: loss}} = sync(hand, "unavailable", attributes(@device_type))
      refute lost.available
      assert is_nil(lost.current_humidity_percent)
      assert is_nil(lost.target_humidity_percent)
      assert is_nil(lost.mode)
      assert is_nil(lost.capabilities.supports_modes)
      assert :capabilities in loss.data.changed
      refute @module.command_arrived?(command.last_command, lost)

      assert Humidity.sync(%{entity_id: "humidifier.other", state: "on", attributes: %{}}, hand) ==
               {:ok, %{}}
    end
  end

  defp assert_rejected(result, text) do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} = result
    assert reason =~ text
  end

  defp device(module, type, settings \\ %{}),
    do: %Dobby.Home.Device{
      id: "#{type}:test",
      name: "Test #{type}",
      agent_module: module,
      bindings: %{humidifier: "humidifier.test"},
      settings: settings
    }

  defp state(module, type, settings \\ %{}),
    do:
      module.new(id: "#{type}:test", state: module.initial_state(device(module, type, settings))).state

  defp entity(type), do: %{state: "on", attributes: attributes(type)}

  defp attributes(type),
    do: %{
      "device_class" => to_string(type),
      "current_humidity" => 42.5,
      "humidity" => 45,
      "min_humidity" => 30,
      "max_humidity" => 70,
      "target_humidity_step" => 5,
      "supported_features" => 1,
      "available_modes" => ["auto", "sleep"],
      "mode" => "auto",
      "action" => "idle"
    }

  defp sync(state, report, attrs) do
    case Humidity.sync(%{entity_id: state.entity_id, state: report, attributes: attrs}, state) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [emit]} -> {Map.merge(state, next), emit}
    end
  end
end
