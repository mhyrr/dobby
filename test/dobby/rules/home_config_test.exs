defmodule Dobby.Rules.HomeConfigTest do
  use ExUnit.Case, async: true

  alias Dobby.Home.Manifest
  alias Dobby.HomeConfig

  defp house do
    [
      id: "probe",
      name: "Probe House",
      timezone: "America/New_York",
      home_assistant: [url: "http://ha.invalid:8123", token: "env:PROBE_TOKEN"],
      devices: [
        %{
          id: "door",
          name: "Front door",
          agent_module: Dobby.DeviceAgents.ContactSensor,
          bindings: %{contact: "binary_sensor.door"},
          settings: %{}
        }
      ]
    ]
  end

  defp config, do: %HomeConfig{path: "/tmp/rules-test.yaml", format: :yaml, house: house()}

  defp definition do
    %{
      "id" => "door-open",
      "name" => "Door left open",
      "source" => "Tell me if the door stays open",
      "device" => "door",
      "kind" => "state",
      "attribute" => "open",
      "operator" => "eq",
      "value" => true,
      "duration_seconds" => 1200
    }
  end

  defp load_yaml(text) do
    path = Path.join(System.tmp_dir!(), "rules-config-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    HomeConfig.load(path)
  end

  test "existing houses have no rules and retain their existing raw keyword shape" do
    assert {:ok, manifest} = Manifest.load(house())
    assert manifest.rules == []
    assert {:ok, loaded} = config() |> HomeConfig.to_yaml() |> load_yaml()
    refute Keyword.has_key?(loaded.house, :rules)
    refute HomeConfig.to_yaml(loaded) =~ "rules:"
  end

  test "YAML round trip preserves rules with booleans, provenance, windows, and pause" do
    raw =
      Map.merge(definition(), %{
        "enabled" => false,
        "window" => %{"start" => "22:00", "end" => "07:00", "days" => [5]}
      })

    assert {:ok, authored} = HomeConfig.add_rule(config(), raw)
    assert {:ok, loaded} = authored |> HomeConfig.to_yaml() |> load_yaml()
    assert loaded.house[:rules] == authored.house[:rules]
    assert {:ok, manifest} = Manifest.load(loaded.house)
    assert [rule] = manifest.rules
    assert rule.value == true
    assert rule.enabled == false
    assert rule.source == raw["source"]
    assert rule.window == raw["window"]
  end

  test "file loading and mutation refuse the same unsupported observable" do
    raw = Map.put(definition(), "attribute", "intent")
    assert {:error, reason} = HomeConfig.add_rule(config(), raw)
    invalid = %{config() | house: Keyword.put(house(), :rules, [raw])}
    assert {:error, ^reason} = invalid |> HomeConfig.to_yaml() |> load_yaml()
    assert {:error, ^reason} = Manifest.load(invalid.house)
  end

  test "rule edits cannot orphan devices, collide ids, or silently rename a rule" do
    assert {:ok, authored} = HomeConfig.add_rule(config(), definition())
    assert {:error, _} = HomeConfig.add_rule(authored, definition())

    assert {:error, _} =
             HomeConfig.update_rule(
               authored,
               "door-open",
               Map.put(definition(), "device", "missing")
             )

    assert {:error, _} =
             HomeConfig.update_rule(authored, "door-open", Map.put(definition(), "id", "renamed"))

    assert {:error, _} = Manifest.load(Keyword.put(authored.house, :devices, []))

    assert {:ok, paused} =
             HomeConfig.update_rule(
               authored,
               "door-open",
               Map.put(definition(), "enabled", false)
             )

    assert [raw] = paused.house[:rules]
    assert raw["enabled"] == false
    assert {:ok, removed} = HomeConfig.delete_rule(paused, "door-open")
    assert removed.house[:rules] == []
    assert {:error, _} = HomeConfig.delete_rule(removed, "door-open")
    assert {:ok, manifest} = Manifest.load(removed.house)
    assert manifest.rules == []
  end

  test "invalid rule list values are refused rather than defaulted empty" do
    for rules <- [nil, %{}, "none"] do
      invalid = %{config() | house: Keyword.put(house(), :rules, rules)}
      assert {:error, _} = Manifest.load(invalid.house)
    end
  end
end
