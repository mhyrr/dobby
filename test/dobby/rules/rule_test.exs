defmodule Dobby.Rules.RuleTest do
  use ExUnit.Case, async: true

  alias Dobby.Home.Device
  alias Dobby.Rules.Rule

  defp device(
         module \\ Dobby.DeviceAgents.ContactSensor,
         bindings \\ %{contact: "binary_sensor.door"}
       ) do
    %Device{id: "door", name: "Front door", agent_module: module, bindings: bindings}
  end

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "door-open",
        "name" => "Door left open",
        "source" => "Tell me if the door stays open for twenty minutes",
        "device" => "door",
        "kind" => "state",
        "attribute" => "open",
        "operator" => "eq",
        "value" => true,
        "duration_seconds" => 1200
      },
      overrides
    )
  end

  test "round trips canonical definitions and retains original words" do
    raw =
      definition(%{
        "enabled" => false,
        "window" => %{"start" => "22:00", "end" => "07:00", "days" => [5, 1]}
      })

    assert {:ok, rule} = Rule.load(raw, [device()])
    assert rule.attribute_key == :open
    assert rule.enabled == false
    assert rule.source == raw["source"]
    assert {:ok, ^rule} = Rule.load(Rule.to_map(rule), [device()])
    assert rule.window["days"] == [1, 5]
    assert Rule.describe(rule) =~ "20 minutes"
    refute Rule.describe(rule) =~ "1200 seconds"
  end

  test "booleans do not mistake missing or unavailable state for a negative condition" do
    assert {:ok, rule} = Rule.load(definition(%{"operator" => "ne"}), [device()])
    assert Rule.matches?(rule, %{available: true, open: false}) == true
    assert Rule.matches?(rule, %{available: true, open: true}) == false

    for snapshot <- [
          %{},
          %{available: true},
          %{available: false, open: false},
          %{available: nil, open: false},
          %{available: true, open: "false"}
        ] do
      assert Rule.matches?(rule, snapshot) == :unknown
    end
  end

  test "offline wifi is observable when HA knows its reachability" do
    raw = definition(%{"attribute" => "online", "value" => false})
    assert {:ok, rule} = Rule.load(raw, [device(Dobby.DeviceAgents.WifiEndpoint)])
    assert Rule.matches?(rule, %{available: true, online: false}) == true
    assert Rule.matches?(rule, %{available: false, online: false}) == :unknown
  end

  test "numeric comparisons include exact boundaries and refuse string numbers" do
    for {operator, expected} <- [
          {"eq", true},
          {"ne", false},
          {"gt", false},
          {"gte", true},
          {"lt", false},
          {"lte", true}
        ] do
      raw =
        definition(%{
          "attribute" => "current_temperature_f",
          "operator" => operator,
          "value" => 60
        })

      assert {:ok, rule} = Rule.load(raw, [device(Dobby.DeviceAgents.Thermostat)])
      assert Rule.matches?(rule, %{available: true, current_temperature_f: 60.0}) == expected
      assert Rule.matches?(rule, %{available: true, current_temperature_f: "60"}) == :unknown
      assert Rule.describe(rule) =~ "60°F"

      assert {:error, _} =
               Rule.load(Map.put(raw, "value", "60"), [device(Dobby.DeviceAgents.Thermostat)])
    end
  end

  test "enum values come from the actual type vocabulary" do
    raw = definition(%{"attribute" => "lock_state", "value" => "unlocked"})
    assert {:ok, rule} = Rule.load(raw, [device(Dobby.DeviceAgents.Lock)])
    assert Rule.matches?(rule, %{available: true, lock_state: :unlocked}) == true
    assert Rule.matches?(rule, %{"available" => true, "lock_state" => "unlocked"}) == true
    assert Rule.matches?(rule, %{available: true, lock_state: :unexpected}) == :unknown

    for value <- ["ajar", :unlocked, 1, nil] do
      assert {:error, _} =
               Rule.load(Map.put(raw, "value", value), [device(Dobby.DeviceAgents.Lock)])
    end

    assert {:error, _} =
             Rule.load(Map.put(raw, "operator", "gt"), [device(Dobby.DeviceAgents.Lock)])
  end

  test "environmental thresholds require a bound reading and its exact unit" do
    monitor = device(Dobby.DeviceAgents.EnvironmentMonitor, %{temperature: "sensor.temp"})

    raw =
      definition(%{
        "attribute" => "temperature",
        "operator" => "lt",
        "value" => 20,
        "unit" => "°C"
      })

    assert {:ok, rule} = Rule.load(raw, [monitor])

    assert Rule.matches?(rule, %{
             available: true,
             readings: %{temperature: 19},
             units: %{temperature: "°C"}
           }) == true

    assert Rule.matches?(rule, %{
             "available" => true,
             "readings" => %{"temperature" => 19},
             "units" => %{"temperature" => "°C"}
           }) == true

    assert Rule.matches?(rule, %{
             available: true,
             readings: %{temperature: 19},
             units: %{temperature: "°F"}
           }) == :unknown

    assert Rule.matches?(rule, %{
             available: true,
             readings: %{temperature: nil, humidity: 40},
             units: %{temperature: "°C"}
           }) == :unknown

    assert {:error, _} = Rule.load(Map.delete(raw, "unit"), [monitor])
    assert {:error, _} = Rule.load(Map.put(raw, "attribute", "humidity"), [monitor])
  end

  test "absence watches a recorded transition to a condition, never command acceptance or unrelated updates" do
    raw =
      definition(%{
        "kind" => "absence",
        "attribute" => "activity",
        "value" => "cleaning",
        "event_kind" => "device_changed",
        "action" => "state_changed"
      })

    assert {:ok, rule} = Rule.load(raw, [device(Dobby.DeviceAgents.Vacuum)])

    event = %{
      device: "door",
      kind: "device_changed",
      action: "state_changed",
      args: %{"changed" => ["activity"]},
      result: %{"available" => true, "activity" => "cleaning"}
    }

    assert Rule.event_matches?(rule, event)
    refute Rule.event_matches?(rule, %{event | device: "another-vacuum"})

    refute Rule.event_matches?(rule, %{event | kind: "control", result: %{"result" => "accepted"}})

    refute Rule.event_matches?(rule, %{event | args: %{"changed" => ["battery_percent"]}})

    refute Rule.event_matches?(rule, %{
             event
             | result: %{"available" => false, "activity" => "cleaning"}
           })

    refute Rule.event_matches?(rule, %{
             event
             | result: %{"available" => true, "activity" => "docked"}
           })

    assert {:error, _} =
             Rule.load(Map.put(raw, "event_kind", "control"), [device(Dobby.DeviceAgents.Vacuum)])

    assert {:error, _} =
             Rule.load(Map.put(raw, "duration_seconds", 0), [device(Dobby.DeviceAgents.Vacuum)])
  end

  test "unsupported and malformed definitions fail without adding vocabulary" do
    for override <- [
          %{"attribute" => "arbitrary"},
          %{"operator" => "contains"},
          %{"value" => "true"},
          %{"value" => nil},
          %{"device" => "missing"},
          %{"enabled" => "yes"},
          %{"enabled" => nil},
          %{"id" => "Bad ID"},
          %{"id" => String.duplicate("x", 81)},
          %{"source" => String.duplicate("x", 2001)},
          %{"source" => 20},
          %{"name" => nil},
          %{"kind" => "automation"},
          %{"duration_seconds" => -1},
          %{"duration_seconds" => 1.5},
          %{"duration_seconds" => 31_536_001},
          %{"duration_seconds" => "20 minutes"},
          %{"execute" => "open"},
          %{"unit" => "°C"},
          %{"action" => "open"}
        ] do
      assert {:error, _} = Rule.load(definition(override), [device()]), inspect(override)
    end

    assert {:error, _} = Rule.load(nil, [device()])
    assert {:error, _} = Rule.load(%{id: "door-open"}, [device()])
    assert {:ok, _} = Rule.load(definition(%{"duration_seconds" => 0}), [device()])
  end

  test "a rule without the household's sentence keeps no sentence, rather than an empty one" do
    # The form and the file authors say what they mean in the fields. Absent,
    # blank, and whitespace all mean the same thing: nobody said it.
    for source <- [nil, "", "   ", "\n"] do
      assert {:ok, rule} = Rule.load(definition(%{"source" => source}), [device()])
      assert rule.source == nil
      refute Map.has_key?(Rule.to_map(rule), "source")
      assert {:ok, ^rule} = Rule.load(Rule.to_map(rule), [device()])
    end

    assert {:ok, rule} = Rule.load(Map.delete(definition(), "source"), [device()])
    assert rule.source == nil
  end

  test "a duration the daily window cannot hold is refused, since the watch restarts at its edge" do
    # 22:00 to 06:00 is eight hours; a rule needing eight hours continuously
    # would never fire, while its description promises it will.
    overnight = %{"start" => "22:00", "end" => "06:00"}

    assert {:error, reason} =
             Rule.load(
               definition(%{"window" => overnight, "duration_seconds" => 28_800}),
               [device()]
             )

    assert reason =~ "shorter than its daily window"
    assert reason =~ "8 hours"

    assert {:ok, rule} =
             Rule.load(
               definition(%{"window" => overnight, "duration_seconds" => 28_799}),
               [device()]
             )

    assert rule.duration_seconds == 28_799
  end

  test "duplicate rules and unbounded rule lists are refused" do
    assert {:error, reason} = Rule.load_all([definition(), definition()], [device()])
    assert reason =~ "duplicate"
    assert {:error, _} = Rule.load_all(List.duplicate(definition(), 101), [device()])
    assert {:error, _} = Rule.load_all(%{}, [device()])
    assert {:ok, []} = Rule.load_all([], [])
  end

  test "every registered device declares observables that exist in its public snapshot" do
    for module <- Dobby.HomeConfig.Types.modules() do
      assert Code.ensure_loaded?(module)
      assert map_size(module.observables()) > 0
      bindings = Map.new(module.subscribed_bindings(), &{&1, "sensor.#{&1}"})
      configured = device(module, bindings)
      agent = module.new(id: configured.id, state: module.initial_state(configured))
      snapshot = module.snapshot(agent.state)

      for {key, type} <- module.observables() do
        if match?({:reading, _}, type) do
          assert Map.has_key?(snapshot, :readings)
          assert key in module.subscribed_bindings()
        else
          assert Map.has_key?(snapshot, key), "#{inspect(module)} declares missing #{key}"
        end
      end
    end
  end

  test "describes the rule in the household's words: as soon as, and days by name" do
    assert {:ok, at_once} = Rule.load(definition(%{"duration_seconds" => 0}), [device()])
    assert Rule.describe(at_once) == "Tell the house as soon as Front door: open equals true."

    weekdays = %{"start" => "20:00", "end" => "07:00", "days" => [1, 2, 3, 4, 5]}
    assert {:ok, rule} = Rule.load(definition(%{"window" => weekdays}), [device()])
    assert Rule.describe(rule) =~ "watching 20:00–07:00 house time on weekdays."
    refute Rule.describe(rule) =~ "Monday is 1"

    some = %{"start" => "20:00", "end" => "07:00", "days" => [1, 3, 5]}
    assert {:ok, rule} = Rule.load(definition(%{"window" => some}), [device()])
    assert Rule.describe(rule) =~ "on Mondays, Wednesdays and Fridays."
  end

  test "a whole-number threshold the tool handed over as a float reads as the number said" do
    assert {:ok, rule} =
             Rule.load(
               definition(%{
                 "device" => "thermostat:main",
                 "attribute" => "current_temperature_f",
                 "operator" => "lt",
                 "value" => 60.0
               }),
               [
                 %Device{
                   id: "thermostat:main",
                   name: "main thermostat",
                   agent_module: Dobby.DeviceAgents.Thermostat,
                   bindings: %{climate: "climate.main_floor"}
                 }
               ]
             )

    assert Rule.condition(rule) == "main thermostat: current temperature is less than 60°F"

    assert {:ok, half} =
             Rule.load(
               definition(%{
                 "device" => "thermostat:main",
                 "attribute" => "current_temperature_f",
                 "operator" => "lt",
                 "value" => 60.5
               }),
               [
                 %Device{
                   id: "thermostat:main",
                   name: "main thermostat",
                   agent_module: Dobby.DeviceAgents.Thermostat,
                   bindings: %{climate: "climate.main_floor"}
                 }
               ]
             )

    assert Rule.condition(half) =~ "60.5°F"
  end
end
