defmodule Dobby.HomeConfigTest do
  @moduledoc """
  The home file, both formats (TK-018).

  Two things are being pinned here. One is that a household's YAML and the rig's
  Elixir arrive at `Dobby.Home` as the same keyword list, because that is what
  lets this change ship without touching the bootstrap, the rig, or a single
  existing test. The other is that a file described wrongly fails saying which
  word was wrong — the posture `Dobby.Home.Manifest` already takes about
  devices, extended to everything else a household writes.
  """

  use ExUnit.Case, async: true

  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Resolver

  @house """
  house:
    id: probe
    name: Probe House
    timezone: America/New_York
    home_assistant:
      url: http://ha.invalid:8123
      token: env:PROBE_TOKEN
    devices:
      - id: thermostat:hall
        type: thermostat
        name: hall thermostat
        aliases: [the thermostat]
        bindings:
          climate: climate.hall
        settings:
          min_temperature_f: 60
          max_temperature_f: 78
  """

  defp write!(contents, extension) do
    path =
      Path.join(
        System.tmp_dir!(),
        "home-config-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

    path
  end

  defp load(contents, extension \\ ".yaml"),
    do: contents |> write!(extension) |> HomeConfig.load()

  describe "reading a house" do
    test "a YAML house arrives as the manifest Dobby.Home already takes" do
      assert {:ok, config} = load(@house)

      assert config.format == :yaml
      assert config.house[:id] == "probe"
      assert config.house[:name] == "Probe House"
      assert config.house[:timezone] == "America/New_York"
      assert config.house[:home_assistant][:url] == "http://ha.invalid:8123"

      assert [device] = config.house[:devices]

      assert device == %{
               id: "thermostat:hall",
               name: "hall thermostat",
               aliases: ["the thermostat"],
               agent_module: Dobby.DeviceAgents.Thermostat,
               bindings: %{climate: "climate.hall"},
               settings: %{min_temperature_f: 60, max_temperature_f: 78}
             }
    end

    test "a house the file describes is a house Dobby.Home will accept" do
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"
      System.put_env(variable, "not-a-real-token")
      on_exit(fn -> System.delete_env(variable) end)

      {:ok, config} = load(String.replace(@house, "env:PROBE_TOKEN", "env:#{variable}"))

      assert {:ok, manifest} = Dobby.Home.Manifest.load(HomeConfig.manifest(config))
      assert [%Dobby.Home.Device{id: "thermostat:hall"}] = manifest.devices
    end

    test "the rig's Elixir manifest reads back exactly as Config.Reader reads it" do
      assert {:ok, config} = HomeConfig.load("config/homes/rig.exs")

      assert config.format == :exs

      assert HomeConfig.manifest(config) ==
               get_in(Config.Reader.read!("config/homes/rig.exs"), [:dobby, Dobby.Home])
    end

    test "the same house in either format describes the same devices" do
      elixir = """
      import Config

      config :dobby, Dobby.Home,
        id: "probe",
        name: "Probe House",
        timezone: "America/New_York",
        home_assistant: [client: Dobby.HomeAssistant.Client, url: "http://ha.invalid:8123"],
        devices: [
          %{
            id: "thermostat:hall",
            name: "hall thermostat",
            aliases: ["the thermostat"],
            agent_module: Dobby.DeviceAgents.Thermostat,
            bindings: %{climate: "climate.hall"},
            settings: %{min_temperature_f: 60, max_temperature_f: 78}
          }
        ]
      """

      assert {:ok, from_yaml} = load(@house)
      assert {:ok, from_exs} = load(elixir, ".exs")

      assert from_yaml.house[:devices] == from_exs.house[:devices]
      assert from_yaml.house[:id] == from_exs.house[:id]
      assert from_yaml.house[:timezone] == from_exs.house[:timezone]
    end

    test "a YAML house talks to the real Home Assistant, which it never has to name" do
      assert {:ok, config} = load(@house)
      assert config.house[:home_assistant][:client] == Dobby.HomeAssistant.Client
    end

    test "every device type is reachable by the word a household writes" do
      yaml = """
      house:
        id: probe
        name: Probe House
        timezone: America/New_York
        home_assistant:
          url: http://ha.invalid:8123
          token: env:PROBE_TOKEN
        devices:
          - id: thermostat:hall
            type: thermostat
            name: hall thermostat
            bindings: {climate: climate.hall}
          - id: light:lamp
            type: light
            name: hall lamp
            bindings: {light: light.lamp}
          - id: vacuum:robot
            type: vacuum
            name: robot vacuum
            bindings: {vacuum: vacuum.robot}
          - id: wifi:printer
            type: wifi_endpoint
            name: office printer
            bindings: {connectivity: binary_sensor.printer}
      """

      assert {:ok, config} = load(yaml)

      assert Enum.map(config.house[:devices], & &1.agent_module) == [
               Dobby.DeviceAgents.Thermostat,
               Dobby.DeviceAgents.Light,
               Dobby.DeviceAgents.Vacuum,
               Dobby.DeviceAgents.WifiEndpoint
             ]
    end

    test "a file that is neither format is refused by name" do
      assert {:error, message} = load("nothing here", ".json")
      assert message =~ ".yaml"
      assert message =~ ".json"
    end

    test "a file that is not there says so rather than crashing" do
      assert HomeConfig.load("config/homes/no-such-house.yaml") == {:error, "no such file"}
    end
  end

  describe "refusing a house, by field" do
    test "a missing scaffolding field is named" do
      yaml = """
      house:
        id: probe
        name: Probe House
        home_assistant:
          url: http://ha.invalid:8123
      """

      assert {:error, message} = load(yaml)
      assert message =~ ~s(house is missing required field "timezone")
    end

    test "a misspelled section is named, with what the file holds" do
      assert {:error, message} = load("houze:\n  id: probe\n")
      assert message =~ ~s(unknown key "houze")
      assert message =~ "house, system"
    end

    test "a misspelled house key is named" do
      yaml = String.replace(@house, "  timezone:", "  timezome:")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(unknown key "timezome")
    end

    test "an unknown device type is named, with the types on offer" do
      yaml = String.replace(@house, "type: thermostat", "type: furnace")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(device "thermostat:hall")
      assert message =~ ~s(unknown type "furnace")
      assert message =~ "thermostat"
      assert message =~ "wifi_endpoint"
    end

    test "an unknown binding is named, with the bindings the type has" do
      yaml = String.replace(@house, "climate: climate.hall", "climat: climate.hall")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(unknown binding "climat")
      assert message =~ "a thermostat binds: climate"
    end

    test "an unknown setting is named, with the settings the type takes" do
      yaml = String.replace(@house, "min_temperature_f:", "min_temp_f:")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(unknown setting "min_temp_f")
      assert message =~ "a thermostat takes: max_temperature_f, min_temperature_f"
    end

    test "a setting on a type that has none says that plainly" do
      yaml = """
      house:
        id: probe
        name: Probe House
        timezone: America/New_York
        home_assistant:
          url: http://ha.invalid:8123
          token: env:PROBE_TOKEN
        devices:
          - id: light:lamp
            type: light
            name: hall lamp
            bindings: {light: light.lamp}
            settings: {brightness: 50}
      """

      assert {:error, message} = load(yaml)
      assert message =~ ~s(unknown setting "brightness")
      assert message =~ "a light takes no settings"
    end

    test "a setting of the wrong shape is named" do
      yaml = String.replace(@house, "min_temperature_f: 60", "min_temperature_f: cold")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(device "thermostat:hall")
      assert message =~ ":min_temperature_f"
    end

    test "a rule spanning two fields is still the device type's to enforce" do
      yaml = String.replace(@house, "max_temperature_f: 78", "max_temperature_f: 50")

      assert {:error, message} = load(yaml)
      assert message =~ "settings.min_temperature_f (60) exceeds max_temperature_f (50)"
    end

    test "a device missing a binding its type requires is refused" do
      yaml = """
      house:
        id: probe
        name: Probe House
        timezone: America/New_York
        home_assistant:
          url: http://ha.invalid:8123
          token: env:PROBE_TOKEN
        devices:
          - id: thermostat:hall
            type: thermostat
            name: hall thermostat
      """

      assert {:error, message} = load(yaml)
      assert message =~ ~s(device "thermostat:hall")
      assert message =~ "missing required binding :climate"
    end

    test "a device with no id still gets an error a person can act on" do
      yaml = """
      house:
        id: probe
        name: Probe House
        timezone: America/New_York
        home_assistant:
          url: http://ha.invalid:8123
          token: env:PROBE_TOKEN
        devices:
          - type: thermostat
            name: hall thermostat
            bindings: {climate: climate.hall}
      """

      assert {:error, message} = load(yaml)
      assert message =~ ~s(device <unnamed> is missing required field "id")
    end

    test "Home Assistant needs somewhere to be" do
      yaml = String.replace(@house, "    url: http://ha.invalid:8123\n", "")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(home_assistant is missing required field "url")
    end

    test "Home Assistant needs a credential reference" do
      yaml = String.replace(@house, "    token: env:PROBE_TOKEN\n", "")

      assert {:error, message} = load(yaml)
      assert message =~ ~s(home_assistant is missing required field "token")
    end

    test "an Elixir home naming a module Dobby does not offer is refused" do
      elixir = """
      import Config

      config :dobby, Dobby.Home,
        id: "probe",
        name: "Probe House",
        timezone: "America/New_York",
        devices: [
          %{
            id: "mystery:one",
            name: "mystery",
            agent_module: Dobby.DeviceAgents.Teleporter,
            bindings: %{}
          }
        ]
      """

      assert {:error, message} = load(elixir, ".exs")
      assert message =~ "Teleporter"
      assert message =~ "not a device type Dobby offers"
    end
  end

  describe "refusing the system section, by field" do
    test "an unknown setting is named, with what the section holds" do
      assert {:error, message} = load(@house <> "system:\n  modle: openai:gpt-5.6-luna\n")
      assert message =~ ~s(unknown setting "modle")
      assert message =~ "model, port, lan, hostname"
    end

    test "a port that is not a port is named" do
      assert {:error, message} = load(@house <> "system:\n  port: four thousand\n")
      assert message =~ "system:"
      assert message =~ ":port"
    end

    test "a hostname is one safe mDNS name" do
      dangerous = @house <> "system:\n  hostname: \"dobby.local'; touch /tmp/nope; '\"\n"

      assert {:error, message} = load(dangerous)
      assert message =~ "system.hostname"
      assert message =~ "one DNS label followed by .local"
    end

    test "an absent system section is a system section of defaults" do
      assert {:ok, config} = load(@house)
      assert config.system == %Dobby.HomeConfig.System{}
      assert config.system.lan == false
      assert config.system.model == nil
    end

    test "the section carries the three knobs runtime.exs used to gate behind dev" do
      system = """
      system:
        model: openai:gpt-5.6-luna
        port: 4001
        lan: true
        hostname: dobby.local
      """

      assert {:ok, config} = load(@house <> system)

      assert config.system == %Dobby.HomeConfig.System{
               model: "openai:gpt-5.6-luna",
               port: 4001,
               lan: true,
               hostname: "dobby.local"
             }
    end
  end

  describe "credentials, by reference" do
    test "the file holds the reference and the manifest holds the value" do
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"
      yaml = String.replace(@house, "env:PROBE_TOKEN", "env:#{variable}")

      System.put_env(variable, "a-real-token")
      on_exit(fn -> System.delete_env(variable) end)

      assert {:ok, config} = load(yaml)
      assert config.house[:home_assistant][:token] == "env:#{variable}"
      assert HomeConfig.manifest(config)[:home_assistant][:token] == "a-real-token"
    end

    test "a literal Home Assistant token is refused by field name" do
      yaml = String.replace(@house, "env:PROBE_TOKEN", "a-long-lived-access-token")

      assert {:error, message} = load(yaml)
      assert message =~ "home_assistant.token"
      assert message =~ "env:VARIABLE"
      assert message =~ "never a credential value"
    end

    test "an unset variable raises once, naming the variable" do
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"
      yaml = String.replace(@house, "env:PROBE_TOKEN", "env:#{variable}")

      assert {:ok, config} = load(yaml)

      assert_raise RuntimeError, ~r/#{variable} is not set/, fn ->
        HomeConfig.manifest(config)
      end
    end

    test "a variable exported empty counts as unset" do
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"
      System.put_env(variable, "")
      on_exit(fn -> System.delete_env(variable) end)

      assert_raise RuntimeError, ~r/#{variable} is not set/, fn ->
        Resolver.resolve!("env:#{variable}")
      end
    end

    test "a value that merely mentions env is left alone" do
      assert Resolver.resolve!("environment") == "environment"
      assert Resolver.resolve!("env:") == "env:"
      refute Resolver.reference?("environment")
      assert Resolver.reference?("env:DOBBY_HA_TOKEN")
    end
  end

  describe "writing a house back out" do
    test "a house round trips through YAML unchanged" do
      yaml = @house <> "system:\n  model: openai:gpt-5.6-luna\n  lan: true\n"

      assert {:ok, config} = load(yaml)
      assert {:ok, again} = load(HomeConfig.to_yaml(config))

      assert again.house == config.house
      assert again.system == config.system
    end

    test "a written file says it is written, and what that costs" do
      {:ok, config} = load(@house)
      rendered = HomeConfig.to_yaml(config)

      assert rendered =~ "# This file is written by Dobby"
      assert rendered =~ "restarts"
    end

    test "a credential is written as the reference it is, never as its value" do
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"
      yaml = String.replace(@house, "env:PROBE_TOKEN", "env:#{variable}")

      System.put_env(variable, "a-real-token")
      on_exit(fn -> System.delete_env(variable) end)

      {:ok, config} = load(yaml)

      rendered = HomeConfig.to_yaml(config)

      assert rendered =~ "env:#{variable}"
      refute rendered =~ "a-real-token"
    end

    test "the rig's Elixir house can be written as the YAML it is becoming" do
      previous_token = System.get_env("DOBBY_HA_TOKEN")
      System.put_env("DOBBY_HA_TOKEN", "fake")

      on_exit(fn ->
        if previous_token do
          System.put_env("DOBBY_HA_TOKEN", previous_token)
        else
          System.delete_env("DOBBY_HA_TOKEN")
        end
      end)

      {:ok, config} = HomeConfig.load("config/homes/rig.exs")

      assert {:ok, migrated} = load(HomeConfig.to_yaml(config))
      assert migrated.house[:home_assistant][:token] == "env:DOBBY_HA_TOKEN"

      assert Enum.map(migrated.house[:devices], & &1.id) ==
               Enum.map(config.house[:devices], & &1.id)

      assert Enum.map(migrated.house[:devices], & &1.bindings) ==
               Enum.map(config.house[:devices], & &1.bindings)

      # A migrated house is still a house: the network a device names is still
      # a network the file declares, so `Dobby.Home.Manifest` accepts it.
      assert {:ok, _manifest} = Dobby.Home.Manifest.load(HomeConfig.manifest(migrated))

      # It says `network: home_wifi` and means the word rather than the atom.
      # Nothing but the file reads these two fields, and a file's vocabulary has
      # no business in the atom table.
      printer = Enum.find(migrated.house[:devices], &(&1.id == "wifi:office_printer"))
      assert printer.network == "home_wifi"
      assert printer.ha_integration == "ping"

      # The two Elixir-only keys are dropped on the way out: a YAML house talks
      # to a real Home Assistant, and the fake's seeded entities are a fixture.
      assert migrated.house[:home_assistant][:client] == Dobby.HomeAssistant.Client
      refute Keyword.has_key?(migrated.house[:home_assistant], :entities)
    end
  end

  describe "the houses that ship" do
    test "the example is a house Dobby would boot, with one of everything" do
      assert {:ok, config} = HomeConfig.load("config/homes/example.yaml")
      assert {:ok, manifest} = Dobby.Home.Manifest.load(stub_credentials(config))

      assert Enum.map(manifest.devices, & &1.agent_module) |> Enum.sort() ==
               Enum.sort(Dobby.HomeConfig.Types.modules())
    end

    test "the example names no real address and holds no credential" do
      contents = File.read!("config/homes/example.yaml")
      {:ok, config} = HomeConfig.load("config/homes/example.yaml")

      assert config.house[:home_assistant][:url] == "env:DOBBY_HA_URL"
      assert config.house[:home_assistant][:token] == "env:DOBBY_HA_TOKEN"
      refute contents =~ ~r/\d+\.\d+\.\d+\.\d+/
    end

    test "the example's model line is commented out, like .env.example's now is" do
      {:ok, config} = HomeConfig.load("config/homes/example.yaml")

      assert config.system.model == nil
      refute File.read!(".env.example") =~ ~r/^DOBBY_MODEL=/m
    end

    test "this house survived the migration with every real value on it" do
      assert {:ok, config} = HomeConfig.load("config/homes/local.yaml")

      assert config.house[:id] == "local"
      assert config.house[:timezone] == "America/New_York"
      assert config.house[:home_assistant][:url] == "env:DOBBY_HA_URL"
      assert config.house[:home_assistant][:token] == "env:DOBBY_HA_TOKEN"

      by_id = Map.new(config.house[:devices], &{&1.id, &1})
      assert map_size(by_id) == 4

      # The furnace, and the settings that keep anyone from asking it for 90.
      honeywell = by_id["thermostat:house"]
      assert honeywell.bindings == %{climate: "climate.thermostat"}
      assert honeywell.aliases == ["the thermostat", "downstairs thermostat"]
      assert honeywell.settings == %{min_temperature_f: 60, max_temperature_f: 78}

      assert by_id["thermostat:main"].bindings == %{climate: "climate.hvac"}
      assert by_id["thermostat:main"].settings == %{min_temperature_f: 60, max_temperature_f: 76}
      assert by_id["light:living_room"].bindings == %{light: "light.living_room_rgbww_lights"}

      assert by_id["wifi:office_printer"].bindings == %{
               connectivity: "binary_sensor.office_printer"
             }

      assert by_id["wifi:office_printer"].ha_integration == "ping"
      assert by_id["wifi:office_printer"].aliases == ["the printer"]

      # The Roomba is still waiting on a human at the robot, and still says so.
      assert File.read!("config/homes/local.yaml") =~ "# - id: vacuum:roomba"
    end
  end

  describe "the test environment's house" do
    test "mix test boots the rig, whatever the shell exports" do
      # The tripwire for the leak this ticket closed: a shell exporting
      # DOBBY_HOME_MANIFEST used to reach every environment, and this suite
      # booted the real client against a real house — whose watcher wrote real
      # device rows into the test database before the sandbox engaged.
      assert Application.get_env(:dobby, Dobby.Home)[:id] == "rig"
      assert Application.get_env(:dobby, :soul_path) == "config/soul.md"
      assert Application.get_env(:dobby, :home_config_path) == "config/homes/rig.exs"
    end

    test "and the port it was told, not the one a shell was thinking of" do
      assert DobbyWeb.Endpoint.config(:http)[:port] == 4002
    end
  end

  # The example ships references and never values — which is the point of it,
  # and means loading it needs something to point at.
  defp stub_credentials(config) do
    Enum.map(config.house, fn
      {:home_assistant, options} ->
        {:home_assistant, Keyword.merge(options, url: "http://ha.invalid:8123", token: "stub")}

      other ->
        other
    end)
  end
end
