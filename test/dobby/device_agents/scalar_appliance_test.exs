defmodule Dobby.DeviceAgents.ScalarApplianceTest do
  @moduledoc """
  Explicit scalar bindings report through HA routing and the typed tool boundary.

  Fixtures describe HA entities, not inferred appliance attributes. Each status
  preserves the difference between unknown readings and facts such as a clear
  warning, a stored target, or an inactive but still hot cooking zone.
  """

  use Dobby.RigCase, async: false

  alias Dobby.DeviceAgents.{CoffeeMaker, Cooktop, IceMaker, Microwave, WineCooler}
  alias Dobby.Tools.{CoffeeMakerGetStatus, CooktopGetStatus, IceMakerGetStatus}
  alias Dobby.Tools.{MicrowaveGetStatus, WineCoolerGetStatus}
  alias Dobby.HomeConfig
  alias Jido.Agent.Directive.Emit

  test "the house reports five appliance types without confusing activity, targets, or warnings" do
    boot_house!(appliances())

    seed_house(%{
      "sensor.coffee_operation" => reading("ready"),
      "binary_sensor.coffee_water" => reading("off"),
      "binary_sensor.coffee_cleaning" => reading("on"),
      "number.wine_upper_target" => reading("12", "°C"),
      "sensor.wine_lower_temperature" => reading("55", "°F"),
      "binary_sensor.wine_door" => reading("off"),
      "sensor.ice_operation" => reading("idle"),
      "binary_sensor.ice_full" => reading("off"),
      "binary_sensor.ice_water" => reading("on"),
      "binary_sensor.cooktop_active" => reading("off"),
      "binary_sensor.cooktop_hot" => reading("on"),
      "sensor.cooktop_power" => reading("0", "%"),
      "sensor.microwave_operation" => reading("cooking"),
      "sensor.microwave_remaining" => reading("0", "s"),
      "sensor.microwave_finish" => reading("2026-09-11T18:30:00-04:00"),
      "binary_sensor.microwave_door" => reading("off"),
      "binary_sensor.microwave_remote" => reading("off")
    })

    assert {:ok, coffee} = Jido.Exec.run(CoffeeMakerGetStatus, %{device: "coffee_maker:kitchen"})
    assert coffee.type == :coffee_maker
    assert coffee.readings.operation_state == "ready"
    assert coffee.readings.water_empty == false
    assert coffee.readings.cleaning_required == true
    assert coffee.readings.beans_empty == nil

    assert {:ok, wine} = Jido.Exec.run(WineCoolerGetStatus, %{device: "wine_cooler:kitchen"})
    assert wine.type == :wine_cooler
    assert wine.readings.upper_target_temperature == 12.0
    assert wine.readings.upper_temperature == nil
    assert wine.readings.lower_temperature == 55.0
    assert wine.readings.door_open == false
    assert wine.units == %{upper_target_temperature: "°C", lower_temperature: "°F"}

    assert {:ok, ice} = Jido.Exec.run(IceMakerGetStatus, %{device: "ice_maker:kitchen"})
    assert ice.type == :ice_maker
    assert ice.readings.operation_state == "idle"
    assert ice.readings.ice_full == false
    assert ice.readings.water_empty == true
    assert ice.readings.cleaning_required == nil

    assert {:ok, cooktop} = Jido.Exec.run(CooktopGetStatus, %{device: "cooktop:front_left"})
    assert cooktop.type == :cooktop
    assert cooktop.readings.active == false
    assert cooktop.readings.hot_surface == true
    assert cooktop.readings.power_level == 0.0
    assert cooktop.units.power_level == "%"

    assert {:ok, microwave} = Jido.Exec.run(MicrowaveGetStatus, %{device: "microwave:kitchen"})
    assert microwave.type == :microwave
    assert microwave.readings.operation_state == "cooking"
    assert microwave.readings.remaining_time == 0.0
    assert microwave.units.remaining_time == "s"
    assert microwave.readings.finish_at == "2026-09-11T18:30:00-04:00"
    assert microwave.readings.door_open == false
    assert microwave.readings.remote_start_allowed == false
    assert Fake.trace() == []
  end

  test "first reports are quiet and unavailable readings lose knowledge independently" do
    for {module, bindings, entity, value, unit, key} <- [
          {CoffeeMaker, %{water_empty: "binary_sensor.water", beans_empty: "binary_sensor.beans"},
           "binary_sensor.water", "off", nil, :water_empty},
          {WineCooler,
           %{upper_temperature: "sensor.upper", upper_target_temperature: "number.target"},
           "number.target", "12", "°C", :upper_target_temperature},
          {IceMaker, %{ice_full: "binary_sensor.full", water_empty: "binary_sensor.water"},
           "binary_sensor.full", "off", nil, :ice_full},
          {Cooktop, %{active: "binary_sensor.active", hot_surface: "binary_sensor.hot"},
           "binary_sensor.hot", "on", nil, :hot_surface},
          {Microwave, %{operation_state: "sensor.operation", remaining_time: "sensor.remaining"},
           "sensor.remaining", "0", "min", :remaining_time}
        ] do
      device = %Dobby.Home.Device{
        id: "#{module.config_type()}:test",
        name: "test appliance",
        agent_module: module,
        bindings: bindings,
        settings: %{}
      }

      state = module.new(id: device.id, state: module.initial_state(device)).state
      [{"ha.state_changed", action}] = module.signal_routes()
      params = %{entity_id: entity, state: value, attributes: %{"unit_of_measurement" => unit}}

      assert {:ok, next, [%Emit{signal: first}]} = Jido.Exec.run(action, params, %{state: state})
      assert first.data.moved == []
      assert next.available
      assert Enum.count(next.readings, fn {_key, reading} -> not is_nil(reading) end) == 1

      state = Map.merge(state, next)

      assert {:ok, lost, [%Emit{signal: event}]} =
               Jido.Exec.run(action, %{params | state: "unavailable"}, %{state: state})

      assert :readings in event.data.moved
      assert lost.readings[key] == nil
      refute lost.available
      refute Map.has_key?(lost.units, key)
    end
  end

  test "status tools refuse wrong types and unknown roster entries" do
    boot_house!(appliances())

    for {tool, wrong_device} <- [
          {CoffeeMakerGetStatus, "wine_cooler:kitchen"},
          {WineCoolerGetStatus, "ice_maker:kitchen"},
          {IceMakerGetStatus, "cooktop:front_left"},
          {CooktopGetStatus, "microwave:kitchen"},
          {MicrowaveGetStatus, "coffee_maker:kitchen"}
        ] do
      assert {:error, wrong_type} = Jido.Exec.run(tool, %{device: wrong_device})
      assert Exception.message(wrong_type) =~ "is not a"
      assert {:error, unknown} = Jido.Exec.run(tool, %{device: "appliance:missing"})
      assert Exception.message(unknown) =~ "unknown device"
    end

    assert Fake.trace() == []
  end

  test "all scalar appliance bindings survive the house YAML round trip" do
    path = Path.join(System.tmp_dir!(), "dobby-scalar-#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(path) end)

    house =
      appliances()
      |> rig_manifest()
      |> Keyword.put(:home_assistant,
        url: "http://ha.invalid:8123",
        token: HomeConfig.Resolver.reference("DOBBY_APPLIANCE_TEST_TOKEN")
      )

    File.write!(path, HomeConfig.to_yaml(%HomeConfig{path: path, format: :yaml, house: house}))
    assert {:ok, loaded} = HomeConfig.load(path)
    assert loaded.house[:devices] == appliances()
  end

  defp appliances do
    [
      appliance(CoffeeMaker, "coffee_maker:kitchen", "Kitchen coffee maker", %{
        operation_state: "sensor.coffee_operation",
        water_empty: "binary_sensor.coffee_water",
        beans_empty: "binary_sensor.coffee_beans",
        cleaning_required: "binary_sensor.coffee_cleaning"
      }),
      appliance(WineCooler, "wine_cooler:kitchen", "Kitchen wine cooler", %{
        upper_temperature: "sensor.wine_upper_temperature",
        upper_target_temperature: "number.wine_upper_target",
        lower_temperature: "sensor.wine_lower_temperature",
        door_open: "binary_sensor.wine_door"
      }),
      appliance(IceMaker, "ice_maker:kitchen", "Kitchen ice maker", %{
        operation_state: "sensor.ice_operation",
        ice_full: "binary_sensor.ice_full",
        water_empty: "binary_sensor.ice_water",
        cleaning_required: "binary_sensor.ice_cleaning"
      }),
      appliance(Cooktop, "cooktop:front_left", "Front left cooking zone", %{
        active: "binary_sensor.cooktop_active",
        hot_surface: "binary_sensor.cooktop_hot",
        power_level: "sensor.cooktop_power"
      }),
      appliance(Microwave, "microwave:kitchen", "Kitchen microwave", %{
        operation_state: "sensor.microwave_operation",
        remaining_time: "sensor.microwave_remaining",
        finish_at: "sensor.microwave_finish",
        door_open: "binary_sensor.microwave_door",
        remote_start_allowed: "binary_sensor.microwave_remote"
      })
    ]
  end

  defp appliance(module, id, name, bindings),
    do: %{
      agent_module: module,
      id: id,
      name: name,
      aliases: [],
      bindings: bindings,
      settings: %{}
    }

  defp reading(state, unit \\ nil),
    do: %{state: state, attributes: if(unit, do: %{"unit_of_measurement" => unit}, else: %{})}
end
