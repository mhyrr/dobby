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
    url: "http://fake.invalid:8123"
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
