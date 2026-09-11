defmodule Dobby.DeviceAgents.ApplianceIntegrationTest do
  @moduledoc """
  Appliance readings travel through the real house and HA subscription route.

  The fixtures use separate HA entities for temperatures and setpoints, as
  the integrations do. A target-only refrigerator must not acquire a measured
  temperature on the way to a tool. Floor heat keeps the thermostat contract.
  """

  use Dobby.RigCase, async: false

  alias Dobby.DeviceAgents.{Dishwasher, Oven, Refrigerator, Thermostat}
  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Discovery
  alias Dobby.Tools.{DishwasherGetStatus, OvenGetStatus, RefrigeratorGetStatus}
  alias Dobby.Tools.{ThermostatGetStatus, ThermostatSetTemperature}

  test "three appliances boot from explicit bindings and report through their status tools" do
    boot_house!(appliances())

    seed_house(%{
      "sensor.dishwasher_operation" => reading("Run"),
      "sensor.dishwasher_progress" => reading("42", "%"),
      "binary_sensor.dishwasher_remote_start" => reading("off"),
      "sensor.oven_temperature" => reading("325", "°F"),
      "sensor.oven_setpoint" => reading("350", "°F"),
      "binary_sensor.oven_running" => reading("on"),
      "number.refrigerator_setpoint" => reading("37", "°F"),
      "binary_sensor.refrigerator_door" => reading("off")
    })

    assert {:ok, dishwasher} = Jido.Exec.run(DishwasherGetStatus, %{device: "dishwasher:kitchen"})
    assert dishwasher.type == :dishwasher
    assert dishwasher.available
    assert dishwasher.readings.operation_state == "Run"
    assert dishwasher.readings.progress == 42.0
    assert dishwasher.units.progress == "%"
    assert dishwasher.readings.remote_start_allowed == false

    assert {:ok, oven} = Jido.Exec.run(OvenGetStatus, %{device: "oven:kitchen"})
    assert oven.type == :oven
    assert oven.available
    assert oven.readings.temperature == 325.0
    assert oven.readings.target_temperature == 350.0
    assert oven.units == %{temperature: "°F", target_temperature: "°F"}
    assert oven.readings.running

    assert {:ok, refrigerator} =
             Jido.Exec.run(RefrigeratorGetStatus, %{device: "refrigerator:kitchen"})

    assert refrigerator.type == :refrigerator
    assert refrigerator.available
    assert refrigerator.readings.refrigerator_target_temperature == 37.0
    assert refrigerator.units.refrigerator_target_temperature == "°F"
    assert refrigerator.readings.refrigerator_door_open == false
    assert is_nil(refrigerator.readings.refrigerator_display_temperature)
    refute Map.has_key?(refrigerator.units, :refrigerator_display_temperature)
    assert Fake.trace() == []
  end

  test "appliance tools refuse unknown devices and other roster types" do
    boot_house!(appliances())

    for {tool, wrong_device} <- [
          {DishwasherGetStatus, "oven:kitchen"},
          {OvenGetStatus, "refrigerator:kitchen"},
          {RefrigeratorGetStatus, "dishwasher:kitchen"}
        ] do
      assert {:error, wrong_type} = tool.run(%{device: wrong_device}, %{})
      assert wrong_type =~ "is not a"
      assert {:error, unknown} = tool.run(%{device: "appliance:missing"}, %{})
      assert unknown =~ "unknown device"
    end

    assert Fake.trace() == []
  end

  test "unbound appliance entities do not create appliance discovery candidates" do
    Fake.put_entity("sensor.unbound_dishwasher", reading("Run"))
    Fake.put_entity("sensor.unbound_oven", reading("350", "°F"))
    Fake.put_entity("number.unbound_refrigerator", reading("37", "°F"))

    for type <- ["dishwasher", "oven", "refrigerator"] do
      assert {:ok, []} = Discovery.candidates(type: type)
    end
  end

  test "discovery separates Sub-Zero appliance climate entities from NuHeat thermostats" do
    Fake.put_entity("climate.connected_oven", %{
      state: "heat",
      attributes: %{friendly_name: "Kitchen oven"},
      platform: "subzero"
    })

    Fake.put_entity("climate.connected_refrigerator", %{
      state: "cool",
      attributes: %{friendly_name: "Kitchen refrigerator"},
      platform: "subzero"
    })

    Fake.put_entity("climate.floor_heat", %{
      state: "auto",
      attributes: %{friendly_name: "Bathroom floor"},
      platform: "nuheat"
    })

    assert {:ok, [%{entity_id: "climate.floor_heat", type: "thermostat", platform: "nuheat"}]} =
             Discovery.candidates(type: "thermostat")
  end

  for mode <- ["heat", "auto"] do
    @mode mode
    test "NuHeat-shaped floor heat reports and accepts a setpoint in #{@mode} mode" do
      boot_house!([
        thermostat_device("thermostat:floor", "Bathroom floor",
          entity: "climate.floor_heat",
          settings: %{}
        )
      ])

      seed_house(%{
        "climate.floor_heat" => %{
          state: @mode,
          attributes: %{
            "current_temperature" => 74,
            "temperature" => 80,
            "min_temp" => 41,
            "max_temp" => 104,
            "target_temp_step" => 1,
            "hvac_modes" => ["heat", "auto"],
            "unit_of_measurement" => "°F"
          }
        }
      })

      assert {:ok, status} = Jido.Exec.run(ThermostatGetStatus, %{device: "thermostat:floor"})
      assert status.available
      assert status.current_temperature_f == 74
      assert status.target_temperature_f == 80
      assert Atom.to_string(status.hvac_mode) == @mode
      assert Thermostat.accepted_range(agent_state("thermostat:floor")) == {41, 104}

      assert {:ok, %{accepted: true, target_temperature_f: 82.0}} =
               Jido.Exec.run(ThermostatSetTemperature, %{
                 device: "thermostat:floor",
                 temperature_f: 82
               })

      assert_receive {:ha_call,
                      %HACall{
                        domain: "climate",
                        service: "set_temperature",
                        entity_id: "climate.floor_heat",
                        data: %{temperature: 82.0}
                      }},
                     2_000

      assert [%HACall{domain: "climate", service: "set_temperature"}] = Fake.trace()
    end
  end

  test "the three explicit appliance bindings survive a YAML round trip" do
    path =
      Path.join(System.tmp_dir!(), "dobby-appliances-#{System.unique_integer([:positive])}.yaml")

    on_exit(fn -> File.rm(path) end)

    house =
      appliances()
      |> rig_manifest()
      |> Keyword.put(:home_assistant,
        url: "http://ha.invalid:8123",
        token: HomeConfig.Resolver.reference("DOBBY_APPLIANCE_TEST_TOKEN")
      )

    config = %HomeConfig{path: path, format: :yaml, house: house}
    File.write!(path, HomeConfig.to_yaml(config))
    assert {:ok, loaded} = HomeConfig.load(path)
    assert loaded.house[:devices] == appliances()

    File.write!(path, HomeConfig.to_yaml(loaded))
    assert {:ok, again} = HomeConfig.load(path)
    assert again.house[:devices] == loaded.house[:devices]
  end

  defp appliances do
    [
      appliance(Dishwasher, "dishwasher:kitchen", "Kitchen dishwasher", %{
        operation_state: "sensor.dishwasher_operation",
        progress: "sensor.dishwasher_progress",
        remote_start_allowed: "binary_sensor.dishwasher_remote_start"
      }),
      appliance(Oven, "oven:kitchen", "Kitchen oven", %{
        temperature: "sensor.oven_temperature",
        target_temperature: "sensor.oven_setpoint",
        running: "binary_sensor.oven_running"
      }),
      appliance(Refrigerator, "refrigerator:kitchen", "Kitchen refrigerator", %{
        refrigerator_target_temperature: "number.refrigerator_setpoint",
        refrigerator_display_temperature: "sensor.refrigerator_display",
        refrigerator_door_open: "binary_sensor.refrigerator_door"
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
