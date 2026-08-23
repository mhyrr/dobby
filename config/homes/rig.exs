import Config

# The rig home (design §12): one representative of each device type, no
# hardware anywhere.
#
# Bound to FakeHA, so this manifest boots the whole
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
      "vacuum.robo" => %{state: "docked", attributes: %{battery_level: 100}},
      "media_player.kitchen" => %{
        state: "paused",
        attributes: %{volume_level: 0.3, is_volume_muted: false, supported_features: 16_389}
      },
      "camera.back_yard" => %{state: "idle", attributes: %{}},
      "event.front_door" => %{
        state: "2026-08-23T12:00:00+00:00",
        attributes: %{event_type: "ring", device_class: "doorbell"},
        device_id: "rig-front-door"
      },
      "camera.front_door" => %{
        state: "idle",
        attributes: %{},
        device_id: "rig-front-door"
      },
      "binary_sensor.front_door_motion" => %{
        state: "off",
        attributes: %{device_class: "motion"},
        device_id: "rig-front-door"
      },
      "lock.front_door" => %{state: "locked", attributes: %{}},
      "cover.garage_door" => %{state: "closed", attributes: %{current_position: 0}},
      "switch.coffee_station" => %{state: "off", attributes: %{}},
      "cover.dining_shade" => %{
        state: "open",
        attributes: %{current_position: 60, supported_features: 4}
      },
      "fan.bedroom" => %{
        state: "on",
        attributes: %{percentage: 35, supported_features: 1}
      },
      "sensor.office_temperature" => %{
        state: "72.4",
        attributes: %{device_class: "temperature", unit_of_measurement: "°F"},
        device_id: "rig-office-air"
      },
      "sensor.office_humidity" => %{
        state: "41",
        attributes: %{device_class: "humidity", unit_of_measurement: "%"},
        device_id: "rig-office-air"
      },
      "binary_sensor.patio_door" => %{
        state: "off",
        attributes: %{device_class: "door"}
      },
      "binary_sensor.hall_occupancy" => %{
        state: "on",
        attributes: %{device_class: "occupancy"}
      },
      "binary_sensor.basement_smoke" => %{
        state: "off",
        attributes: %{device_class: "smoke"}
      },
      "sensor.garage_opener_temperature" => %{
        # Diagnostic on purpose, and permanently. This is the one rig entity a
        # type recognizes (a temperature is an environment monitor's word) that
        # discovery must never offer: HA marks it as the opener's internals,
        # not the household's air. DiscoveryTest reads this file and holds the
        # tripwire — remove this entry or the filter, and the suite says so.
        state: "88.1",
        attributes: %{device_class: "temperature", unit_of_measurement: "°F"},
        device_id: "rig-garage-opener",
        entity_category: "diagnostic"
      }
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
      id: "speaker:kitchen",
      name: "kitchen speaker",
      aliases: ["kitchen Sonos"],
      agent_module: Dobby.DeviceAgents.Speaker,
      bindings: %{media_player: "media_player.kitchen"},
      settings: %{}
    },
    %{
      id: "camera:back_yard",
      name: "back yard camera",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Camera,
      bindings: %{camera: "camera.back_yard"},
      settings: %{}
    },
    %{
      id: "doorbell:front",
      name: "front doorbell",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Doorbell,
      bindings: %{
        event: "event.front_door",
        camera: "camera.front_door",
        motion: "binary_sensor.front_door_motion"
      },
      settings: %{}
    },
    %{
      id: "lock:front",
      name: "front door lock",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Lock,
      bindings: %{lock: "lock.front_door"},
      settings: %{}
    },
    %{
      id: "cover:garage",
      name: "garage door",
      aliases: [],
      agent_module: Dobby.DeviceAgents.AccessCover,
      bindings: %{cover: "cover.garage_door"},
      settings: %{}
    },
    %{
      id: "switch:coffee",
      name: "coffee station",
      aliases: [],
      agent_module: Dobby.DeviceAgents.PowerSwitch,
      bindings: %{switch: "switch.coffee_station"},
      settings: %{}
    },
    %{
      id: "shade:dining",
      name: "dining room shade",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Shade,
      bindings: %{cover: "cover.dining_shade"},
      settings: %{}
    },
    %{
      id: "fan:bedroom",
      name: "bedroom fan",
      aliases: [],
      agent_module: Dobby.DeviceAgents.Fan,
      bindings: %{fan: "fan.bedroom"},
      settings: %{}
    },
    %{
      id: "monitor:office",
      name: "office air",
      aliases: [],
      agent_module: Dobby.DeviceAgents.EnvironmentMonitor,
      bindings: %{
        temperature: "sensor.office_temperature",
        humidity: "sensor.office_humidity"
      },
      settings: %{}
    },
    %{
      id: "contact:patio",
      name: "patio door",
      aliases: [],
      agent_module: Dobby.DeviceAgents.ContactSensor,
      bindings: %{contact: "binary_sensor.patio_door"},
      settings: %{}
    },
    %{
      id: "occupancy:hall",
      name: "hall occupancy",
      aliases: [],
      agent_module: Dobby.DeviceAgents.OccupancySensor,
      bindings: %{occupancy: "binary_sensor.hall_occupancy"},
      settings: %{}
    },
    %{
      id: "safety:basement",
      name: "basement smoke detector",
      aliases: [],
      agent_module: Dobby.DeviceAgents.SafetySensor,
      bindings: %{alarm: "binary_sensor.basement_smoke"},
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
