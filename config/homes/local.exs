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
    # The demo thermostat, first on purpose: `mix dobby.ha.verify
    # --round-trip` nudges the first thermostat it finds, and the default
    # nudge should land on the virtual one, never the furnace.
    %{
      id: "thermostat:main",
      name: "demo thermostat",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: "climate.hvac"},
      settings: %{min_temperature_f: 60, max_temperature_f: 76}
    },
    # The real Honeywell, through its RedLINK gateway and the TCC cloud —
    # the first entry in any manifest describing hardware that exists.
    # Cloud-polled, so a commanded change confirms in seconds-to-a-minute,
    # not instantly; the acceptance/observation split absorbs that.
    %{
      id: "thermostat:house",
      name: "house thermostat",
      aliases: ["the thermostat", "downstairs thermostat"],
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: "climate.thermostat"},
      settings: %{min_temperature_f: 60, max_temperature_f: 78}
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
    },
    # The Roomba, once HA holds its credentials — the one step that needs a
    # human at the robot (docs/local-ha.md, "The Roomba"). Fill in the
    # vacuum.* entity id HA creates, then uncomment:
    #
    # %{
    #   id: "vacuum:roomba",
    #   name: "robot vacuum",
    #   aliases: ["the vacuum", "the roomba"],
    #   agent_module: Dobby.DeviceAgents.Vacuum,
    #   bindings: %{vacuum: "vacuum.roomba"},
    #   settings: %{}
    # },
    # The actual printer, presence by ICMP: HA's ping integration pings
    # 192.168.86.218 and Dobby reads the resulting binary_sensor. If its DHCP
    # lease ever moves, fix the address in HA's ping entry — a reservation in
    # the router is the durable answer.
    %{
      id: "wifi:office_printer",
      name: "office printer",
      aliases: ["the printer"],
      agent_module: Dobby.DeviceAgents.WifiEndpoint,
      ha_integration: :ping,
      bindings: %{connectivity: "binary_sensor.office_printer"},
      settings: %{}
    }
  ]
