import Config

# The rig home (design §12): one thermostat, no hardware anywhere.
#
# Bound to FakeHA at the one honest boundary, so this manifest boots the whole
# real application — real device agents, real bootstrap, real DobbyAgent — in
# both `mix test` and `mix phx.server`, with no Proxmox, no HAOS, and no house.
config :dobby, Dobby.Home,
  id: "rig",
  name: "Rig Home",
  timezone: "America/New_York",
  home_assistant: [
    client: Dobby.HomeAssistant.Fake,
    url: "http://fake.invalid:8123",
    # The state the fake starts holding, so `mix phx.server` boots a house you
    # can look at. A real client learns this from Home Assistant on subscribe;
    # the fake has to be told, and being told here keeps the whole description
    # of the rig in one file. `Fake.reset/0` clears it, which is why the test
    # suite still starts from a house that knows nothing.
    entities: %{
      "climate.main_floor" => %{
        state: "heat",
        attributes: %{
          current_temperature: 66,
          temperature: 70,
          min_temp: 50,
          max_temp: 90,
          target_temp_step: 1,
          hvac_modes: ["off", "heat"]
        }
      },
      "binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}},
      "binary_sensor.office_printer" => %{state: "off", attributes: %{}},
      "light.living_room" => %{
        state: "on",
        attributes: %{brightness: 128, supported_color_modes: ["color_temp", "hs"]}
      },
      "vacuum.robo" => %{state: "docked", attributes: %{battery_level: 100}}
    }
  ],
  networks: [
    %{id: :home_wifi, name: "Rig", ssid: "rig"}
  ],
  devices: [
    %{
      id: "thermostat:main",
      name: "main thermostat",
      aliases: ["downstairs thermostat"],
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: "climate.main_floor"},
      settings: %{min_temperature_f: 60, max_temperature_f: 76}
    },
    %{
      id: "light:living_room",
      name: "living room light",
      aliases: ["living room lamp"],
      agent_module: Dobby.DeviceAgents.Light,
      bindings: %{light: "light.living_room"},
      settings: %{}
    },
    %{
      id: "vacuum:robo",
      name: "robot vacuum",
      aliases: ["the vacuum"],
      agent_module: Dobby.DeviceAgents.Vacuum,
      bindings: %{vacuum: "vacuum.robo"},
      settings: %{}
    },
    %{
      id: "wifi:kitchen_tv",
      name: "kitchen TV",
      aliases: ["kitchen television"],
      agent_module: Dobby.DeviceAgents.WifiEndpoint,
      network: :home_wifi,
      ha_integration: :ping,
      bindings: %{connectivity: "binary_sensor.kitchen_tv"},
      settings: %{}
    },
    %{
      id: "wifi:office_printer",
      name: "office printer",
      aliases: [],
      agent_module: Dobby.DeviceAgents.WifiEndpoint,
      network: :home_wifi,
      ha_integration: :ping,
      bindings: %{connectivity: "binary_sensor.office_printer"},
      settings: %{}
    }
  ]
