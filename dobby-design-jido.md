# Dobby — Simple Jido Design

**Draft v0.7 — August 2026**

**Status:** first build; supersedes the broader v0.4 architecture. The original
household vision remains in `dobby-design-original.md`.

## 1. The first thing we are building

Dobby v1 is a Phoenix application with one LLM-backed Jido agent and a small
set of deterministic Jido device agents.

The LLM-backed `DobbyAgent` receives what someone says, determines which device
agents should handle it, and sends each one a typed action. Device agents own
their allowed behavior and use Home Assistant to reach the physical devices.
The LLM never calls Home Assistant or invents a device operation.

The whole system is:

```text
User → Phoenix → DobbyAgent ─┬→ ThermostatAgent ─┐
                             ├→ WifiEndpointAgent ├→ Home Assistant → devices
                             └→ WifiEndpointAgent ┘
```

One request may target one device agent or several. “Set the thermostat to 70
and tell me which endpoints are offline” produces a list of typed actions that
are dispatched to the relevant agents concurrently.

For the first build, there are only two device-agent types:

- `ThermostatAgent` — reports thermostat state and changes its setpoint.
- `WifiEndpointAgent` — reports whether a configured Wi-Fi endpoint is online.

Nothing else belongs in v1.

## 2. Physical deployment

### 2.1 One Linux mini-server

Start with the cloud-inference hardware option from the original design:

- N100-class or similar x86-64 mini-PC;
- 32 GB RAM;
- 1 TB NVMe;
- wired Ethernet to the home router or mesh node;
- a small UPS.

No GPU is required for v1 because the DobbyAgent uses a cloud model. The model
provider remains configurable through Jido AI/ReqLLM. If household use later
justifies local inference, a GPU machine can replace the model endpoint without
changing the device-agent design.

Install Proxmox VE on the physical server and run two virtual machines:

```text
Physical mini-server — Proxmox VE
├── VM 1: Home Assistant OS
│   ├── 2 vCPU
│   ├── 4 GB RAM
│   └── 32–64 GB virtual disk
└── VM 2: Debian services
    ├── 2–4 vCPU
    ├── 8 GB RAM initially
    ├── 64–128 GB virtual disk
    └── Phoenix + Jido + Postgres
```

The allocations are starting points, not reservations of physical cores.
Proxmox can adjust them later. The remaining memory and disk give HA recorder
history, Postgres, backups, and future services room to grow.

Home Assistant publishes an official KVM/Proxmox-compatible HAOS image. HAOS is
an appliance VM containing Home Assistant Core, its supervisor, and its managed
services; it is not installed inside Phoenix or the Debian VM.

### 2.2 What Home Assistant does

Home Assistant is the device hub. Its integrations know how to talk to Nest,
Nuheat, local network devices, and future device protocols. Each integration
turns vendor-specific hardware into normalized entities:

```text
physical thermostat
  → vendor/local protocol
  → HA thermostat integration
  → climate.main_floor

network endpoint
  → HA Ping or device-tracker integration
  → binary_sensor.kitchen_tv or device_tracker.some_device
```

HA owns the credentials, vendor APIs, protocol details, and observed physical
state. Dobby sees the resulting entities and invokes HA actions. It never talks
to the thermostat or router directly.

The exact thermostat integration cannot be chosen from the design document; we
must identify the installed thermostat and verify which `climate.*` entity and
attributes HA exposes.

For Wi-Fi endpoints, v1 means endpoint reachability, not household presence.
HA's Ping integration can expose fixed-IP endpoints as binary sensors. Give
those devices DHCP reservations first. The official Google Wifi integration
reports router health but does not provide a client roster. Phones are also poor
ping targets because they may sleep their Wi-Fi radios. Presence stays deferred
until we have a reliable `device_tracker` source.

## 3. Network and ingress

Both VMs attach to Proxmox's LAN bridge and receive stable DHCP leases. The
server itself should use Ethernet; household browsers can remain on Wi-Fi.

```text
Household browser
    │ Wi-Fi / LAN
    ▼
dobby.local                    Debian VM: Phoenix + Jido + Postgres
    │ WebSocket over LAN
    ▼
homeassistant.local:8123       HAOS VM
    │ local or vendor-cloud integrations
    ▼
thermostat and network entities

DobbyAgent ── outbound HTTPS only ──► model provider
```

V1 ingress is the Phoenix LiveView at `http://dobby.local`. Phoenix owns the
browser session, conversation UI, and request log, then sends each utterance to
the DobbyAgent. A static IP address remains the fallback if mDNS does not cross
the mesh cleanly.

There is no inbound port forwarding. Dobby and HA are available only on the
home LAN. Tailscale remote access, Telegram, and voice are later additions.

Phoenix remains the common ingress when voice arrives:

```text
HA voice satellite → HA Assist → local Phoenix endpoint → DobbyAgent
```

Voice changes how a request enters the application; it does not create another
Dobby brain or another device-control path.

## 4. Defining a home

The codebase contains a reusable library of device-agent modules. A particular
home is data: one committed manifest declares the home, its networks, and the
agent instances that should run there.

Use `config/home.exs`. It is ordinary Elixir configuration, imported by
`config/config.exs`, so v1 needs no configuration parser or additional file
format dependency. Changes take effect after an application restart.

An illustrative home definition:

```elixir
import Config

config :dobby, Dobby.Home,
  id: "foo",
  name: "Foo Home",
  timezone: "America/New_York",
  home_assistant: [
    url: "http://homeassistant.local:8123"
  ],
  networks: [
    %{id: :home_wifi, name: "Foo", ssid: "foo"}
  ],
  devices: [
    %{
      id: "thermostat:main",
      name: "main thermostat",
      aliases: ["downstairs thermostat"],
      agent_module: Dobby.DeviceAgents.Thermostat,
      ha_integration: :nest,
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
    }
  ]
```

The Home Assistant token and model API key do not belong in this file. They are
runtime secrets supplied to the Debian VM. The manifest may contain household
names, aliases, HA entity IDs, and the Wi-Fi SSID; it never contains the Wi-Fi
password or vendor credentials.

This separates three things that should not collapse into one class hierarchy:

- **agent module** — reusable behavior such as `Thermostat` or `WifiEndpoint`;
- **device instance** — `thermostat:main` with its name, settings, and bindings;
- **HA integration** — Nest, Ping, Nuheat, or another implementation underneath
  HA's normalized entity model.

We therefore do not create `NestThermostatAgent` and
`NuheatThermostatAgent`. Both should use the same thermostat module when HA
exposes the behavior Dobby needs. Vendor information remains useful for
inventory and debugging but does not determine Dobby's orchestration.

A physical device may have several HA entities. `bindings` is a named map rather
than a single `entity_id` for that reason. A future camera instance might bind
`:stream`, `:motion`, and `:package_event` to three HA entities while using one
reusable `Camera` agent module.

Every physical device Dobby manages gets its own manifest entry. A home with one
thermostat, two cameras, and three Wi-Fi endpoints therefore has six device
entries but only three reusable agent modules. The manifest records which
physical thing is which; it never says merely `camera_count: 2`.

### 4.1 Home startup

`Dobby.Home` performs one small bootstrap job:

1. load and validate the manifest;
2. reject duplicate IDs, aliases, missing networks, unknown agent modules, or
   invalid module-specific settings;
3. start one Jido agent instance for each device entry;
4. start DobbyAgent with a roster containing names, aliases, IDs, and advertised
   actions;
5. configure the shared HA client with the entity-to-agent routing table derived
   from the bindings.

Configuration errors fail application startup with the exact device and field
that are wrong. Silently skipping a thermostat because of a typo would make the
house unusually philosophical about heating.

### 4.2 Device-agent library

The initial in-project library is:

```text
lib/dobby/device_agents/
├── thermostat.ex
├── thermostat/
│   ├── get_status.ex
│   └── set_temperature.ex
├── wifi_endpoint.ex
└── wifi_endpoint/
    └── get_status.ex
```

Each agent module supplies four things:

- a schema for its `bindings` and `settings`;
- the Jido Actions it permits and advertises to DobbyAgent;
- translation from relevant HA state into its deterministic agent state;
- translation from effectful Actions into HA Directives.

That is the extension contract. We should implement it plainly for Thermostat
and WifiEndpoint before extracting a macro or separate Hex package. The shared
shape has to emerge from real modules first.

Adding a supported device behavior later means:

1. add one module under `Dobby.DeviceAgents` and its Actions;
2. test its configuration, HA state translation, and HA Directives;
3. add one or more instances to `config/home.exs`;
4. restart Dobby.

The bootstrap automatically starts the instances, routes their HA entities, and
adds their actions to the DobbyAgent roster. No central switch statement changes.

The manifest defines what Dobby currently manages, not every object HA knows
about. When `Camera` exists, the two Nest cameras are added to the manifest. HA
remains the full hardware inventory in the meantime.

## 5. Runtime shape

The two VM boundaries and the Elixir processes inside Dobby are:

```text
HAOS VM
└── Home Assistant
    ├── thermostat integration
    ├── Ping/device-tracker integrations
    └── WebSocket API

Debian services VM
├── Postgres
└── Dobby.Application
    ├── Dobby.Repo
    ├── Dobby.PubSub
    ├── DobbyWeb.Endpoint
    ├── Dobby.HomeAssistant.Client          one shared HA connection
    ├── Dobby.Jido
    │   ├── DobbyAgent                      LLM-backed
    │   ├── ThermostatAgent: main           deterministic
    │   ├── WifiEndpointAgent: endpoint_a   deterministic
    │   └── WifiEndpointAgent: endpoint_b   deterministic
    └── Dobby.Home                          validates config and starts agents
```

The Jido runtime and HA client start before `Dobby.Home` bootstraps DobbyAgent
and the configured device agents.

The endpoint names are placeholders until inventory. V1 starts agents only for
devices configured explicitly. It does not discover every HA entity and turn it
into an agent.

Each device agent has a stable Dobby ID such as `thermostat:main` or
`wifi:endpoint_a`. The LLM selects those IDs; ordinary code uses Jido's registry
to find the processes. Process IDs and HA entity IDs never appear in model
output.

## 6. DobbyAgent and multi-agent dispatch

`DobbyAgent` is Dobby's language and orchestration agent. It sees:

- the user's utterance;
- short conversation history;
- the configured device agents, their names, and their allowed actions.

It returns a clarification, a conversational response, or a list of typed
device actions:

```elixir
[
  %Dobby.DeviceAction{
    id: "action-1",
    target: "thermostat:main",
    action: :set_temperature,
    args: %{temperature_f: 70}
  },
  %Dobby.DeviceAction{
    id: "action-2",
    target: "wifi:endpoint_a",
    action: :get_status,
    args: %{}
  }
]
```

The output schema is closed. Every target must be a registered device-agent ID;
every action must be advertised by that agent type; and its arguments must match
the action schema.

DobbyAgent dispatches all actions after the one structured model response. It
does not call the model once per device. Each device agent returns a result with
the same request and action IDs. DobbyAgent gathers the results and completes
the request even when one device fails:

```text
Thermostat set to 70°. Endpoint A is online. Endpoint B did not respond.
```

V1 uses deterministic result templates, so aggregation does not require a
second model call. We can add richer conversational rendering after this path is
fast and reliable.

There is no separate parser, planner, coordinator, generic effect language, or
approval component in v1.

## 7. Device agents and the Home Assistant boundary

A device agent is a Jido AgentServer running a direct deterministic strategy.
It owns:

- its stable Dobby ID and friendly name;
- its HA entity binding;
- its small set of permitted actions;
- interpretation of that entity's HA state;
- translation of permitted actions into HA operations;
- validation particular to that device.

It does not own an HA credential or network connection. All device agents share
one `Dobby.HomeAssistant.Client`, which owns:

- authentication;
- the WebSocket connection and reconnect behavior;
- HA request IDs and responses;
- the `state_changed` subscription;
- routing entity updates to the bound device agent.

This prevents one connection per device and keeps networking out of the agent
logic. The division is:

```text
ThermostatAgent knows:     set_temperature → climate.set_temperature
HomeAssistant.Client knows: encode/send/reconnect/authenticate the HA message
Home Assistant knows:       how to reach and operate the physical thermostat
```

In Jido terms, a device agent validates an Action and emits a Home Assistant
Directive. The shared client executes that Directive. Inbound HA state changes
become Signals sent to the device agent. Those are the only two directions.

### 7.1 ThermostatAgent

State:

```elixir
%{
  entity_id: "climate.main_floor",
  available: true,
  current_temperature_f: 68,
  target_temperature_f: 70,
  hvac_mode: :heat
}
```

V1 actions:

- `get_status`
- `set_temperature`

`set_temperature` validates a configured household range and emits an HA call
for `climate.set_temperature`. Mode changes, schedules, holds, and recovery
behavior wait until the basic agent works with the installed thermostat.

### 7.2 WifiEndpointAgent

State:

```elixir
%{
  entity_id: "binary_sensor.endpoint_a",
  available: true,
  online: true,
  last_changed_at: ~U[2026-08-13 12:00:00Z]
}
```

V1 action:

- `get_status`

This agent is read-only. It translates the configured HA entity into `online`,
`offline`, or `unknown`. Restarting routers, blocking clients, presence
inference, and alerts are later behaviors.

## 8. Requests end to end

For “set the main thermostat to 70”:

1. Phoenix sends the text to `DobbyAgent`.
2. The model returns `thermostat:main / set_temperature / 70°F`.
3. DobbyAgent sends the typed action to `ThermostatAgent`.
4. ThermostatAgent validates the target temperature and emits an HA Directive.
5. The shared HA client sends `climate.set_temperature` to HAOS.
6. HA's thermostat integration talks to the actual thermostat.
7. HA publishes the changed `climate.*` state over the WebSocket.
8. The HA client routes that state to ThermostatAgent.
9. ThermostatAgent updates its state and Dobby completes the request.

For “which endpoints are offline,” DobbyAgent emits `get_status` to every
configured WifiEndpointAgent at once and gathers their deterministic replies.

Direct controls in Phoenix bypass the LLM but follow the same lower path:

```text
Phoenix control → ThermostatAgent → HA client → HAOS → thermostat
```

## 9. Phoenix surface and persistence

The first LiveView contains:

- one conversation box;
- a card for the thermostat agent;
- a card for each Wi-Fi endpoint agent;
- a short request/result log.

Device-card controls send actions straight to deterministic device agents. This
gives us a no-LLM path for testing and for model outages.

Postgres stores conversations and the request/result log. Device state remains
owned by HA and is rebuilt in the agents after restart.

## 10. What we are deliberately not designing yet

- room and space agents;
- a HouseCoordinator;
- generic effects and plans;
- standing policies and policy authoring;
- presence inference;
- schedules and cron behavior;
- workflows, scenes, and multi-device transactions;
- Telegram, voice, cameras, Sonos, and a broad dashboard;
- automatic device discovery or dashboard editing of `home.exs`;
- multiple houses;
- local model hosting.

These remain possible. None is allowed to shape the first implementation until
the thermostat and Wi-Fi agents work through both direct Phoenix controls and
the DobbyAgent.

## 11. Build order

### Step 1 — Server and HAOS

Install Proxmox on the mini-server, create the HAOS VM from the official image,
attach it to the LAN bridge, assign a stable DHCP lease, and complete HA
onboarding.

### Step 2 — Real HA entities and home manifest

Identify and configure the installed thermostat integration. Configure two or
three fixed endpoints through HA Ping or another proven integration. Record the
actual entity IDs, states, attributes, and thermostat actions. This is the only
required inventory. Write those instances into `config/home.exs`.

### Step 3 — Debian and Phoenix

Create the Debian services VM, install Postgres, and create the Phoenix/Jido
application. Implement `Dobby.Home` validation and start the device agents from
the manifest.

### Step 4 — Shared HA client

Connect one WebSocket client to HA, load the configured entities' current
states, subscribe to state changes, and route those changes to their device
agents. Display the live values in Phoenix.

### Step 5 — Direct deterministic actions

Make `get_status` work for both agent types and make `set_temperature` work from
the thermostat card. Test invalid temperature and unavailable-device behavior.

### Step 6 — DobbyAgent

Add Jido AI. Give the model only the configured device roster and action
schemas. Prove:

- “What's the main thermostat set to?”
- “Set the thermostat to 70.”
- “Which endpoints are offline?”
- “Set the thermostat to 69 and check all the endpoints.”
- one ambiguous device name that must produce a clarification.

### Step 7 — Use it on the LAN

Serve the LiveView at `dobby.local`, use it against the real house, and record
failures and latency. The next ingress, device behavior, or abstraction is chosen
from actual use.

## 12. Current decisions

1. Phoenix is the first ingress and household interface; later ingress channels
   feed the same DobbyAgent.
2. Jido supplies the agents, runtime, actions, signals, and directives.
3. One LLM-backed DobbyAgent may dispatch one request to multiple device agents.
4. Device agents are deterministic and own their HA binding, state translation,
   allowed actions, validation, and HA operation mapping.
5. One shared HA client owns authentication, transport, subscriptions, and
   reconnect behavior.
6. HAOS runs in its own Proxmox VM and owns physical device integration and
   observed state.
7. V1 includes only one thermostat and a few read-only Wi-Fi endpoints.
8. Reusable agent modules live in `Dobby.DeviceAgents`; concrete homes and
   device instances are declared in `config/home.exs`.
9. Vendor integration is metadata and an HA concern, not the device-agent class
   hierarchy.
10. The first implementation optimizes for a working vertical slice, not a
   general smart-home ontology.

## Sources

- [Jido agents](https://jido.run/docs/concepts/agents)
- [Jido agent runtime](https://jido.run/docs/concepts/agent-runtime)
- [Jido actions](https://jido.run/docs/concepts/actions)
- [Jido directives](https://jido.run/docs/concepts/directives)
- [Home Assistant OS virtual-machine installation](https://www.home-assistant.io/installation/alternative/)
- [Home Assistant WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)
- [Home Assistant Ping integration](https://www.home-assistant.io/integrations/ping/)
- [Home Assistant device trackers](https://www.home-assistant.io/integrations/device_tracker/)
- [Home Assistant Google Wifi integration](https://www.home-assistant.io/integrations/google_wifi/)
