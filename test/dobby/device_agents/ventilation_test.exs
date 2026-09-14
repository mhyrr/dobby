defmodule Dobby.DeviceAgents.VentilationTest do
  use Dobby.RigCase, async: false
  alias Dobby.DeviceAgents.{AirPurifier, RangeHood, Ventilation}
  alias Jido.Agent.Directive.Emit

  for {module, kind, tools} <- [
        {AirPurifier, :air_purifier,
         [
           Dobby.Tools.AirPurifierGetStatus,
           Dobby.Tools.AirPurifierTurnOn,
           Dobby.Tools.AirPurifierSetSpeed
         ]},
        {RangeHood, :range_hood,
         [
           Dobby.Tools.RangeHoodGetStatus,
           Dobby.Tools.RangeHoodTurnOn,
           Dobby.Tools.RangeHoodSetSpeed
         ]}
      ] do
    @device_module module
    @kind kind
    @tools tools

    test "#{kind} binds native fan controls and independent filter readings through live agents" do
      d = device(@device_module, @kind)
      boot_house!([Map.from_struct(d)])

      seed_house(%{
        "fan.test" => %{state: "off", attributes: %{"percentage" => 0, "supported_features" => 1}},
        "sensor.filter" => %{state: "75", attributes: %{"unit_of_measurement" => "%"}}
      })

      [status_tool, on_tool, speed_tool] = @tools

      assert {:ok, %{type: kind, readings: %{filter_remaining: 75}, power: :off} = status} =
               Jido.Exec.run(status_tool, %{device: d.id})

      # The library answers in `device`, and a status tool that handed its
      # snapshot straight back would answer in `id`.
      assert status.device == d.id
      refute Map.has_key?(status, :id)

      assert kind == @kind
      id = d.id

      for {tool, args, service, field, value} <- [
            {on_tool, %{}, "turn_on", :power, :on},
            {speed_tool, %{speed_percent: 40}, "set_percentage", :speed_percent, 40}
          ] do
        assert {:ok, %{accepted: true}} = Jido.Exec.run(tool, Map.put(args, :device, id))

        assert_receive {:ha_call,
                        %HACall{domain: "fan", service: ^service, entity_id: "fan.test"}},
                       2_000

        assert_receive %Jido.Signal{
                         type: "dobby.device.state_changed",
                         data: %{
                           commanded?: true,
                           snapshot: %{^field => ^value, id: ^id, type: ^kind}
                         }
                       },
                       2_000
      end

      :ok =
        Fake.inject_state_changed("fan.test", %{
          state: "unavailable",
          attributes: %{
            "percentage" => 40,
            "supported_features" => 1
          }
        })

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: %{id: ^id, available: false}}
                     },
                     2_000

      assert {:ok, %{accepted: false}} = Jido.Exec.run(on_tool, %{device: id})

      assert {:ok,
              %{
                available: false,
                power: nil,
                speed_percent: nil,
                readings: %{filter_remaining: 75}
              }} =
               Jido.Exec.run(status_tool, %{device: id})

      assert length(Fake.trace()) == 2
      settle_watcher!()

      # Two commands this house issued, plus the fan going quiet. Home
      # Assistant's turn-on moves the power and restores the speed in one
      # report, and a seam that accounted for only one of them told the
      # household somebody had walked up to the fan. Nothing here was anybody's
      # but ours, so the thread has nothing to say.
      assert Enum.filter(Dobby.Conversation.list_messages(), &(&1.role == :system)) == []
    end

    test "#{kind} sensor changes cannot authorize fan control or become command echoes" do
      d = device(@device_module, @kind)
      state = @device_module.new(id: d.id, state: @device_module.initial_state(d)).state

      params = %{
        entity_id: "sensor.filter",
        state: "75",
        attributes: %{"unit_of_measurement" => "%"}
      }

      assert {:ok, first, [%Emit{signal: learned}]} =
               Ventilation.sync(params, state, @device_module.reading_types(), @kind)

      assert learned.data.moved == []
      assert is_nil(learned.data.snapshot.available)

      assert {:ok, %{last_command: %{result: {:rejected, _}}}} =
               Dobby.DeviceAgents.Fan.SetPower.run(%{power: :on, ref: "cmd"}, %{
                 state: Map.merge(state, first)
               })

      known =
        Map.merge(state, first)
        |> Map.put(:last_command, %{action: :set_power, power: :on, result: :accepted})

      assert {:ok, _, [%Emit{signal: changed}]} =
               Ventilation.sync(
                 %{params | state: "70"},
                 known,
                 @device_module.reading_types(),
                 @kind
               )

      assert changed.data.moved == [:readings]
      refute changed.data.commanded?

      assert {:ok, _, [%Emit{signal: lost}]} =
               Ventilation.sync(
                 %{params | state: "unknown"},
                 known,
                 @device_module.reading_types(),
                 @kind
               )

      assert lost.data.snapshot.readings.filter_remaining == nil
      refute Map.has_key?(lost.data.snapshot.units, :filter_remaining)

      for bindings <- [
            %{fan: "switch.wrong"},
            %{fan: "fan."},
            %{fan: "fan.test", filter_remaining: "binary_sensor.wrong"}
          ] do
        assert {:error, _} = @device_module.validate_device(%{d | bindings: bindings})
      end
    end
  end

  defp device(module, kind),
    do: %Dobby.Home.Device{
      id: "#{kind}:test",
      name: "Test #{kind}",
      agent_module: module,
      bindings: %{fan: "fan.test", filter_remaining: "sensor.filter"},
      settings: %{}
    }
end
