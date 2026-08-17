import Config

# The local home (docs/local-ha.md): a real Home Assistant in a container on
# this machine, demo entities, no hardware. The same application as the rig,
# bound to the real client at the one honest boundary — which makes this file
# the first manifest describing a house that exists outside the BEAM.
#
#     DOBBY_HOME_MANIFEST=config/homes/local.exs \
#     DOBBY_HA_TOKEN=<token> \
#     mix phx.server
#
# The credential comes from the environment because this file is committed
# and tokens never are. `dev/home-assistant/onboard.exs` mints one.
config :dobby, Dobby.Home,
  id: "local",
  name: "Local Home",
  timezone: "America/New_York",
  home_assistant: [
    client: Dobby.HomeAssistant.Client,
    url: System.get_env("DOBBY_HA_URL", "http://localhost:8123"),
    token:
      System.get_env("DOBBY_HA_TOKEN") ||
        raise("""
        DOBBY_HA_TOKEN is not set.

        The local manifest talks to a real Home Assistant, which requires a
        long-lived access token. Start and initialize the local instance —
        see docs/local-ha.md — and export the token it prints.
        """)
  ],
  networks: [],
  devices: [
    # The demo integration's full-featured thermostat. Its hardware envelope
    # (45–95°F on this instance) comes from capability discovery; settings
    # narrow it to household policy, exactly as in the rig.
    %{
      id: "thermostat:main",
      name: "main thermostat",
      aliases: ["downstairs thermostat", "the thermostat"],
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: "climate.hvac"},
      settings: %{min_temperature_f: 60, max_temperature_f: 76}
    },
    # A demo light that dims — whether Dobby may be asked for brightness is
    # discovered from its supported_color_modes, not assumed here.
    %{
      id: "light:living_room",
      name: "living room light",
      aliases: ["living room lamp"],
      agent_module: Dobby.DeviceAgents.Light,
      bindings: %{light: "light.living_room_rgbww_lights"},
      settings: %{}
    }
  ]
