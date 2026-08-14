# Dobby — Simple Jido Design

**Draft v0.11 — August 2026**

**Status:** under construction. Phase A step 1 is built and green (§12), and
this revision is the first one written from working code rather than from
research. The original household vision remains in `dobby-design-original.md`.

Changes from v0.10 are corrections the rig forced, not new ideas. Three places
where the design was simply wrong about the libraries: `tools:` cannot be
derived at compile time (§6.1); per-turn context cannot ride on the user
message (§6.3); and `get_status` is a tool, not a device action (§7.1). One
addition: Dobby's voice is now a file on the box rather than a string in the
release (§6.6). Measured numbers replace estimates in §6.5 and §8.

Changes from v0.8: the household surface is one shared Discord-like thread
with system lines for actuations; device identity is cookie-pinned, not
MAC-based; Dobby owns schedules as Postgres rows authored conversationally and
fired deterministically — reversing the original design's rule that HA
executes all schedules (§9); an admin dashboard carries the activity feed and
scheduler; and the build order is test-rig-first, with hardware in parallel
rather than as a prerequisite.

Changes from v0.9: Dobby is one Phoenix application, not an umbrella, deployed
as an OTP release under `/opt/dobby` (§2.3–2.4); the home manifest is read at
runtime from the box rather than compiled in, so editing the house costs a
restart and not a rebuild (§4); and device agents discover their capabilities
from Home Assistant and consult an optional vendor profile keyed by
`ha_integration` (§4.3).

## 1. The first thing we are building

Dobby v1 is a Phoenix application with one LLM-backed Jido agent and a small
set of deterministic Jido device agents.

The LLM-backed `DobbyAgent` is a long-running conversational agent. It holds
the household conversation, keeps a current picture of every managed device,
and acts through a closed set of typed device tools. Each tool dispatches to a
deterministic device agent; device agents own their allowed behavior and use
Home Assistant to reach the physical devices. The LLM never calls Home
Assistant and cannot invent a device operation.

The whole system is:

```text
User → Phoenix → DobbyAgent ─┬→ ThermostatAgent ─┐
                             ├→ WifiEndpointAgent ├→ Home Assistant → devices
                             └→ WifiEndpointAgent ┘
```

One request may touch one device agent or several. “Set the thermostat to 70
and tell me which endpoints are offline” becomes tool calls against the
thermostat agent and every Wi-Fi endpoint agent, and the model composes one
reply from their actual results.

Utterances arrive as an envelope, not a bare string:

```elixir
%Dobby.Utterance{speaker: "greg", channel: :web, text: "set the thermostat to 70"}
```

Anyone in the house talks to the same Dobby, in the same thread. `speaker`
exists for personalization and attribution, never for permissions — the Wi-Fi
password remains the trust boundary, as in the original design. `channel` is
`:web` today and `:voice` later; a new channel changes how an utterance
enters, not what handles it.

For the first build, there are only two device-agent types:

- `ThermostatAgent` — reports thermostat state and changes its setpoint.
- `WifiEndpointAgent` — reports whether a configured Wi-Fi endpoint is online.

Plus one deterministic house-level agent: `SchedulerAgent`, which fires stored
schedules (§9). Nothing else belongs in v1.

## 2. Deployment

### 2.1 One Linux mini-server

Start with the cloud-inference hardware option from the original design:

- N100-class or similar x86-64 mini-PC;
- 32 GB RAM;
- 1 TB NVMe;
- wired Ethernet to the home router or mesh node;
- a small UPS.

No GPU is required for v1 because the DobbyAgent uses a cloud model. Jido AI
resolves models through configured aliases backed by ReqLLM, and ReqLLM
accepts a `base_url` override, so pointing the same alias at a local
OpenAI-compatible server later is a configuration change, not a design change.

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

### 2.3 Application structure

One Phoenix application, not an umbrella. §5's boot order — the Jido instance
and the HA client up before `Dobby.Home` starts agents — is one supervision
tree; an umbrella would split it into several and turn that ordering into a
`mix.exs` puzzle, for a boundary it does not really provide since umbrella
children share configuration anyway. When the device library earns a boundary
it becomes a `Jido.Plugin` (§4.2), which is a library and can be extracted from
a single application without restructuring anything.

```text
dobby/
├── config/
│   ├── config.exs dev.exs test.exs prod.exs
│   ├── runtime.exs                  secrets, home manifest, soul path
│   ├── soul.md                      who Dobby is (§6.6)
│   └── homes/
│       ├── foo.exs                  the real house
│       └── rig.exs                  FakeHA bindings for dev and test
├── lib/
│   ├── dobby/
│   │   ├── application.ex
│   │   ├── jido.ex                  use Jido, otp_app: :dobby
│   │   ├── home.ex                  bootstrap (§4.1)
│   │   ├── home/{manifest,device}.ex
│   │   ├── device_agent.ex          the extension contract (§4.2)
│   │   ├── device_agents/           §4.2
│   │   ├── profiles/                §4.3, deferred to Phase C
│   │   ├── home_assistant.ex        behaviour — the one honest boundary
│   │   ├── home_assistant/
│   │   │   ├── websocket.ex         real client
│   │   │   └── fake.ex              the rig (§12)
│   │   ├── directives/ha_call.ex
│   │   ├── agent.ex                 DobbyAgent + doctrine
│   │   ├── agent/{request_transformer,observe_device}.ex
│   │   ├── soul.ex                  reads config/soul.md at boot
│   │   ├── device_events.ex         the state_changed seam (§7)
│   │   ├── tools/                   one thin Jido.Action per capability
│   │   ├── scheduler/{agent,schedule}.ex
│   │   ├── conversation/{utterance,transcript}.ex
│   │   └── activity/log.ex
│   └── dobby_web/                   thread, cards, admin, endpoint, router
├── priv/repo/migrations/
├── rel/                             release overlays
└── test/support/
    ├── rig_case.ex                  boots real houses against FakeHA
    ├── trace.ex                     telemetry → per-source assertions
    └── script.ex                    multi-tool turns the DSL can't express
```

Tools live in their own directory rather than under `device_agents/` because a
tool is the model's surface and a device agent is the house's; keeping them
apart is what lets a read be served without inventing a device action for it
(§7.1).

`FakeHA` lives in `lib/`, not `test/support/`, because the rig is a runtime
surface and not only a test fixture: `mix phx.server` in dev boots the entire
application — thread, cards, scheduler — against it with no VM present.

### 2.4 Deploying and running

Dobby ships as an OTP release built on the Debian VM itself, which avoids the
ERTS and glibc mismatches that come from building elsewhere. Code lives in git;
state lives on the box:

```text
/opt/dobby/
├── src/                        git clone — built from, never run
├── releases/
│   └── 2026-09-14-3f1e0cd/     self-contained, includes ERTS
├── current -> releases/2026-09-14-3f1e0cd
├── config/
│   ├── home.exs                the deployed manifest (§4)
│   ├── soul.md                 who Dobby is (§6.6)
│   └── dobby.env               chmod 600: DATABASE_URL, SECRET_KEY_BASE,
│                               HA token, model API key
└── data/backups/               pg_dump output
```

Deploy is: pull; `MIX_ENV=prod mix do deps.get, compile, assets.deploy, release
--path releases/$STAMP`; copy the manifest and the soul into
`/opt/dobby/config/`; repoint `current`; `bin/dobby eval
"Dobby.Release.migrate()"`; `systemctl restart dobby`. Postgres is an ordinary
package install on the same VM, and `dobby.env` is the systemd unit's
`EnvironmentFile`.

**Changing the house does not require a release.** All three files under
`/opt/dobby/config/` are read at boot by `runtime.exs` (§4, §6.6), so
correcting an entity ID, adding an endpoint, rotating a token, or rewriting
how Dobby talks is edit-and-restart. Only changes to code or to compile-time
configuration need a rebuild.

Containers were considered and set aside. `/opt/dobby/current/bin/dobby remote`
— a live IEx shell into the running node, for inspecting device-agent state or
replaying a signal against the real house — is the primary debugging surface
for this system, and a container layer buys nothing on a single-tenant box.

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
browser session, speaker identity, the thread UI, and the request log, then
sends each utterance envelope to the DobbyAgent. A static IP address remains
the fallback if mDNS does not cross the mesh cleanly.

There is no inbound port forwarding. Dobby and HA are available only on the
home LAN. Tailscale remote access, Telegram, and voice are later additions.

Phoenix remains the common ingress when voice arrives:

```text
HA voice satellite → HA Assist → local Phoenix endpoint → DobbyAgent
```

Voice enters as `channel: :voice` with the speaker resolved by room default or
left unknown until speaker identification exists, and its utterances appear in
the same thread as everyone else's. It does not create another Dobby brain or
another device-control path.

## 4. Defining a home

The codebase contains a reusable library of device-agent modules. A particular
home is data: one committed manifest declares the home, its networks, and the
agent instances that should run there.

A manifest is ordinary Elixir configuration, so v1 needs no configuration
parser or additional file-format dependency. Manifests live in `config/homes/`
and are read at boot by `runtime.exs` — deliberately *not* imported by
`config/config.exs`:

```elixir
manifest =
  System.get_env("DOBBY_HOME_MANIFEST") ||
    case config_env() do
      :prod -> "/opt/dobby/config/home.exs"
      _ -> "config/homes/rig.exs"
    end

config :dobby, Dobby.Home, get_in(Config.Reader.read!(manifest), [:dobby, Dobby.Home])
```

Reading it at runtime is what makes "changes take effect after a restart" true
on the box (§2.4). Imported into `config/config.exs` it would be compile-time
configuration frozen into the release, and every corrected entity ID would cost
a rebuild and a redeploy. The manifest is still committed — it is the versioned
truth about the house — and the deploy step copies it to
`/opt/dobby/config/home.exs`. (`import_config` is unavailable in
`runtime.exs`; `Config.Reader.read!/1` is the supported path.)

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
      ha_integration: :nest,          # profile key (§4.3); omit to auto-detect
      bindings: %{climate: "climate.main_floor"},
      settings: %{min_temperature_f: 60, max_temperature_f: 76}  # policy only (§4.3)
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
`NuheatThermostatAgent`. Both use the same thermostat module. Vendor identity
is a lookup key into an optional profile of device-specific semantics (§4.3) —
never a subclass, and never a second orchestration path.

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
3. start one Jido agent instance for each device entry, registered in
   `Jido.Registry` under its Dobby ID;
4. start SchedulerAgent, which loads enabled schedules from Postgres (§9);
5. start DobbyAgent and install its soul (§6.6). The roster and the house's
   tool set are *not* passed at startup — both are read from the manifest per
   request, for the reason in §6.1;
6. configure the shared HA client with the entity-to-agent routing table derived
   from the bindings.

The order is load-bearing, and so is waiting. `Jido.start_agent/2` returns
before `AgentServer` has built its signal routes in a `handle_continue`, so the
bootstrap synchronises on each agent before moving on. Without that barrier the
initial state Home Assistant sends on subscribe races DobbyAgent's routing
table, and whether Dobby knows the house at boot depends on scheduling.

Configuration errors fail application startup with the exact device and field
that are wrong. Silently skipping a thermostat because of a typo would make the
house unusually philosophical about heating. The soul is required on the same
grounds: a Dobby with no soul runs the house correctly and sounds like nobody
in particular, which is easy to ship and hard to notice.

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
- the Jido Actions it permits, which are also what DobbyAgent advertises to the
  model as tools;
- translation from relevant HA state into its deterministic agent state;
- translation from effectful Actions into HA commands, emitted as directives
  (§7).

That is the extension contract. We should implement it plainly for Thermostat
and WifiEndpoint before extracting anything. When extraction happens, the
target is a `Jido.Plugin` — Jido 2.x's packaging for a reusable bundle of
actions, state slice, signal routes, and config schema (the concept that
replaced 1.x Skills) — not a bespoke macro. The shared shape still has to
emerge from real modules first.

Adding a supported device behavior later means:

1. add one module under `Dobby.DeviceAgents` and its Actions;
2. test its configuration, HA state translation, and HA command directives;
3. add one or more instances to `config/homes/foo.exs`;
4. restart Dobby.

The bootstrap automatically starts the instances, routes their HA entities, and
adds their actions to the DobbyAgent tool set. No central switch statement
changes.

The manifest defines what Dobby currently manages, not every object HA knows
about. When `Camera` exists, the two Nest cameras are added to the manifest. HA
remains the full hardware inventory in the meantime.

### 4.3 Capabilities and device profiles

HA normalizes the *shape* of a device — a `climate` entity has a target
temperature, hvac modes, bounds, a step, presets — but not its *meaning*. That
distinction produces two rules.

**Capabilities are discovered, not declared.** On first state sync a device
agent reads `min_temp`, `max_temp`, `target_temp_step`, `hvac_modes`,
`preset_modes`, and `supported_features` from its bound entity. That is the
device's real envelope. The manifest's `settings` only narrow it to household
policy, and validation is the intersection of the two. A manifest can then no
longer authorize a setpoint the hardware rejects, and the tool schema the model
sees derives from the actual device rather than from a number typed months
earlier.

**Semantics need a profile.** NuHeat is the concrete case: its preset modes are
Run Schedule, Temporary Hold, and Permanent Hold, and `climate.set_temperature`
means different things depending on mode — in auto it holds until the next
scheduled event; in heat mode it holds *permanently*. A generic agent mapping
`set_temperature → climate.set_temperature` would therefore silently destroy
the thermostat's onboard schedule, which is the original design's §7.5 Nuheat
wrinkle resurfacing one layer down. None of it is visible in
`supported_features`. Nest fails differently: `heat_cool` wants a range rather
than a scalar, and eco mode swallows setpoints. Radiant floor heat also carries
45–90 minutes of thermal lag, which makes "70 by 8pm" a materially different
request than it is on forced air — exactly the ambiguity §6.2 asks the model to
clarify.

A profile is keyed by `ha_integration` and supplies up to three things:

- semantic flags the module's actions consult — `setpoint_semantics: :hold`,
  `owns_onboard_schedule: true`, `thermal_lag: :high`;
- prose merged into DobbyAgent's device snapshot (§6.3), so judgment about lag
  and holds reaches the model as context rather than being hard-coded;
- rarely, an overridden HA mapping — a `set_preset_mode` and `set_temperature`
  pair, or a vendor-domain action such as `nuheat.set_temperature`.

Profiles are **optional**. With none, the agent behaves generically from
discovered capabilities alone. A NuHeat thermostat therefore works the day it
is added to the manifest; the profile makes it correct. That property is what
keeps the library from becoming a compatibility matrix that must be extended
before anyone can add hardware.

`ha_integration` may be omitted entirely. HA's WebSocket API exposes
`config/entity_registry/list`, whose entries carry the providing `platform`,
and `config/device_registry/list`, which carries `manufacturer` and `model`.
Dobby detects the integration from the entity registry at boot and treats a
manifest value as an override, logging any mismatch. The same lookup supplies
most of the inventory work in §12.6.

Profiles are deferred, not scaffolded. Thermostat and WifiEndpoint are built
generically with capability discovery in Phase A; the first profile is written
in Phase C against the real thermostat, out of a real conflict — the same
discipline §4.2 applies to the Plugin extraction. The one concession made in
advance is the seam: actions take a profile that defaults to a generic one, so
adding NuHeat later is a new module rather than a rewrite.

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
    ├── Dobby.Jido                            Jido instance: registry, supervisors
    ├── Dobby.HomeAssistant.Client            one shared HA connection
    ├── DobbyAgent                            Jido.AI agent (ReAct), long-running
    ├── SchedulerAgent                        Jido agent, Direct strategy, fires schedules
    ├── ThermostatAgent  "thermostat:main"    Jido agent, Direct strategy
    ├── WifiEndpointAgent "wifi:endpoint_a"   Jido agent, Direct strategy
    ├── WifiEndpointAgent "wifi:endpoint_b"   Jido agent, Direct strategy
    └── Dobby.Home                            validates config and starts agents
```

`Dobby.Jido` (`use Jido, otp_app: :dobby`) provides the registry and
supervisors. The Jido instance and HA client start before `Dobby.Home`
bootstraps DobbyAgent and the configured device agents. All agents are static
children started from the manifest; nothing is spawned dynamically in v1, so
Jido's parent-child spawning machinery stays unused.

The endpoint names are placeholders until inventory. V1 starts agents only for
devices configured explicitly. It does not discover every HA entity and turn it
into an agent.

Each device agent has a stable Dobby ID such as `thermostat:main` or
`wifi:endpoint_a`, which is also its `Jido.Registry` ID. The LLM selects those
IDs in tool arguments; ordinary code resolves them through the registry.
Process IDs and HA entity IDs never appear in model output.

## 6. DobbyAgent

`DobbyAgent` is Dobby's language and orchestration agent, and it is where the
design leans hardest on Jido: one long-lived `Jido.AI.Agent` process (the ReAct
strategy) that accumulates the household conversation, holds a live picture of
device state, and reaches the world only through typed tools.

### 6.1 Shape

```elixir
defmodule Dobby.DobbyAgent do
  use Jido.AI.Agent,
    name: "dobby",                        # literal: see below
    model: :capable,                      # alias in config, swappable per §2.1
    tools: [                              # the library, not the house
      Dobby.Tools.ThermostatGetStatus,
      Dobby.Tools.ThermostatSetTemperature,
      Dobby.Tools.WifiGetStatus
    ],
    system_prompt: @doctrine,             # voice arrives at boot (§6.6)
    max_iterations: 5,
    streaming: true,
    request_transformer: Dobby.DobbyAgent.RequestTransformer,
    signal_routes: [
      {"dobby.device.state_changed", Dobby.DobbyAgent.ObserveDevice}
    ]
end
```

**Every option here must be a literal.** `Jido.AI.Agent` reads them at
macro-expansion time: `:tools` raises `CompileError` on a function call, and
`:name` is stringified straight from the AST, so even a module attribute
fails. Earlier drafts wrote `tools: Dobby.Home.tools()`, which does not
compile.

So the compile-time list is the *library* — every tool module that exists in
this codebase — and the manifest narrows it to this house per request, through
the `:tools` option on `ask/3`. `Dobby.Home.tools/0` supplies that list.

The closed-by-construction guarantee is unchanged and arguably sharper: the
model still sees only tools for devices this house actually has, and adding a
device type is still one module plus a manifest line. The one unavoidable
central edit is appending the new tool module to the literal above.

Phoenix delivers each utterance with `ask_stream/3`; the reply streams back to
the LiveView. The default request policy serializes turns, which is correct for
a household: one thing at a time, in one shared conversation.

### 6.2 Tools, closed by construction

The model's only means of acting is the `tools:` list — one tool per agent
module action, with a `device` argument constrained to the configured roster,
plus the schedule-authoring tools:

```text
thermostat_get_status(device)
thermostat_set_temperature(device, temperature_f)
wifi_get_status(device)

create_schedule(label, cron, device, action, args)
list_schedules()
set_schedule_enabled(id, enabled)
delete_schedule(id)
```

Pause and resume are one tool with a flag rather than two verbs, which is the
one place the built surface differs from what this section first named. Two
modules differing by a boolean is duplication looking for somewhere to drift,
and the trade — a verb per intent is one less thing for a model to get wrong —
is measurable rather than arguable: both models tested turn "pause the morning
warmup schedule" into `set_schedule_enabled(enabled: false)`, and the one that
had never seen the id looks it up with `list_schedules` first. If that stops
holding, splitting them back is a small change.

Each tool is a thin `Jido.Action` whose arguments are validated against its
schema before it runs — malformed or unknown-device calls are rejected and the
error returns to the model as an observation, not an exception. Its `run/2`
dispatches to the target device agent through the registry and returns the
device agent's actual result to the model. Domain validation (the household
temperature range, device availability) still lives in the device agent; the
tool layer adds nothing but transport.

A tool schema is a contract with the model, and it is possible to write one
that contradicts itself. `jido_action` renders a NimbleOptions union type such
as `{:or, [:integer, :float]}` into the JSON schema as `"type": "string"`, so a
model is told to send `"70"`, correctly sends `"70"`, and is then rejected by
our own validation. Numeric arguments use `:float` — which renders as
`"number"` — plus an `on_before_validate_params/1` coercion, because JSON has
one number type and Elixir has two. This class of bug is invisible to scripted
tests, whose fixtures are written by hand; it is exactly what the eval tier is
for (§12).

Ambiguity is a refusal to act, and specifically not a licence to act broadly.
"The thermostat" in a house with two thermostats is an ambiguous request, not
permission to change both — a real model, given only the instruction not to
guess, set both. The system prompt now separates a request naming one device
from a request naming several ("all the endpoints").

Reads are answered from device-agent state immediately — no HA round trip,
because agent state is kept current by the HA subscription (§7). Writes return
acceptance: the device agent validated the command and emitted it to HA.
Physical confirmation arrives asynchronously as a state change, and the system
prompt tells the model to report what it commanded, not to claim observation of
what it cannot see. The same rule extends to schedules: the model reports a
schedule as created, never as already-applied device state.

Schedule authoring is where language work concentrates: “I always want the
thermostat at 70 by 8pm on weekdays” must normalize to an explicit cron spec
and typed action — and “at 70 by 8pm” is genuinely ambiguous (at 8pm sharp, or
ramped to reach 70 by then?), so the model clarifies rather than guesses.

### 6.3 State and awareness

DobbyAgent's statefulness is explicit, not incidental:

- **Conversation.** The ReAct strategy accumulates turns in `Jido.AI.Context`
  automatically for the life of the process. Jido provides no compaction, so
  Dobby caps the projected history at the last N turns and persists the full
  transcript to Postgres; summarization can replace truncation later without
  changing the shape.
- **World model.** Device agents emit a `dobby.device.state_changed` signal on
  every meaningful change (§7). DobbyAgent routes that signal into a snapshot
  of last-known device state via a custom `signal_routes` entry, which composes
  with the `Jido.AI.Agent` macro and executes under the ReAct strategy — the
  ETS read-model fallback earlier drafts hedged with is unnecessary. Each turn,
  `Jido.AI.Reasoning.ReAct.RequestTransformer` (callback `transform_request/4`;
  no `PromptBuilder` fallback needed) injects the roster and current snapshot
  as a tagged `<house>` block.

That block is a **separate message placed immediately before the utterance**,
not appended to the utterance itself as earlier drafts specified. Two reasons,
and the second is the binding one. It stays out of the system prompt to
preserve prompt caching. And `Jido.AI.Test.ReActScript` matches a scripted turn
to a request by exact string equality against the *last user message*, so
decorating the utterance would force every replay scenario to spell out the
whole rendered block and would break all of them on any prompt change. Placing
it before leaves the raw utterance last, which keeps both properties.

The speaker prefix (§6.4) stays on the utterance, because it has to survive
into conversation history. `Dobby.Utterance.to_message/1` is its single
definition, used by production and by test scripts alike, so the format cannot
silently desynchronize the two.

So the model always knows what devices exist, what state they were last in,
and who is speaking, before it decides whether to answer, clarify, or act.
The world model is also the seam future proactive behavior hangs off — the
signals already arrive; v1 simply does nothing with them beyond awareness.

One property to design around rather than forget: the fan-out to the world
model is asynchronous (`Task.Supervisor.async_stream`), so the thread having
an event is not evidence that DobbyAgent has it. The world model is eventually
consistent with device state, and a turn beginning immediately after a device
change may read the previous value.

### 6.4 Multi-user

The household shares one conversation on one long-lived process — Jido AI's
documented pattern is one agent process per conversation, and the house is one
conversation. Each user message is prefixed with its speaker
(`[greg] set the thermostat to 70`), so the model can attribute, personalize,
and address people by name across interleaved speakers. Per-user private
threads, if ever wanted, are per-speaker agent instances sharing the same
device agents; that stays deferred.

### 6.5 Replies and cost

The model composes every reply from real tool results inside the ReAct loop.
Rendering "Thermostat set to 70°. Endpoint B did not respond." is exactly what
the loop's final turn is for, and clarification questions fall out of the same
mechanism instead of needing a schema branch — including multi-turn ones: a
clarifying question and the answer to it are ordinary turns, and "the
downstairs one" resolves against the question asked a moment earlier with no
outstanding-question state anywhere in the system.

Measured, rather than estimated (gpt-4.1 and gpt-5.6-luna, one household
request, FakeHA underneath):

```text
actuating       2 model turns   ~1,900 in / ~50 out tokens    1.7–2.7 s
clarification   1 model turn      ~600 in / ~40 out tokens    0.9–1.8 s
```

Two turns per actuating request, at the low end of this section's original
two-to-three estimate. Input tokens dominate and are dominated in turn by the
second turn resending context, which makes prompt caching the lever if cost
ever argues. `max_iterations` caps the loop, and Jido AI's quota and
model-routing plugins remain available knobs.

There is no separate parser, planner, coordinator, generic effect language, or
approval component in v1.

### 6.6 Soul and doctrine

The system prompt is two halves with deliberately different lifecycles.

**The soul** is who Dobby is — tone, brevity, how he talks about himself. It
lives in `config/soul.md`, is read at boot, and is installed onto the running
agent with the `ai.react.set_system_prompt` signal. It sits beside the home
manifest in `/opt/dobby/config/` and gets the same property for the same
reason (§2.4): editing the personality of the thing you live with costs a
restart, never a release. A bad edit produces an annoying housemate.

**The doctrine** is the set of rules that keep Dobby honest — never invent a
device, never act on a guess, report what you commanded rather than what you
observed. It lives in code, in `Dobby.DobbyAgent.doctrine/0`, and changes
under review. A bad edit produces a house that lies about whether the heat is
on.

They are composed soul first, doctrine last, so on any conflict between
personality and honesty the doctrine is what the model read most recently. The
compile-time `system_prompt:` is doctrine alone, which is the floor: if the
soul never installs, Dobby is charmless but still honest.

The split exists because rewriting a personality should not be able to quietly
delete a safety rule. It also makes voice testable — the eval tier can ask
whether a new soul survived contact with a real model, and whether it survives
*changing* models, which is the stricter question. It does: the same voice
comes back from two different providers.

The failure mode is quiet enough to warrant a structural test rather than an
eyeball — a soul that never loads leaves a house that works perfectly and
sounds like nobody in particular.

## 7. Device agents and the Home Assistant boundary

A device agent is a `Jido.Agent` on the default Direct strategy running under
`Jido.AgentServer` — deterministic, signal-driven, long-lived. It owns:

- its stable Dobby ID and friendly name;
- its HA entity bindings;
- its small set of permitted actions;
- interpretation of its entities' HA state;
- translation of permitted actions into HA commands;
- validation particular to that device.

It does not own an HA credential or network connection. All device agents share
one `Dobby.HomeAssistant.Client`, which owns:

- authentication;
- the WebSocket connection and reconnect behavior;
- HA request IDs and responses;
- the `state_changed` subscription;
- routing entity updates to the bound device agent.

The two directions, in concrete Jido 2.x terms:

**Outbound.** Actions never perform side effects. An effectful action returns a
custom directive describing the HA command:

```elixir
%Dobby.Directive.HACall{
  domain: "climate",
  service: "set_temperature",
  entity_id: "climate.main_floor",
  data: %{temperature: 70}
}
```

A `Jido.AgentServer.DirectiveExec` implementation hands it to the shared
client. This is the documented extension point for external-effect directives —
the agent stays pure and testable, the runtime owns the effect.

**Inbound.** The client turns each relevant `state_changed` event into an
`ha.state_changed` signal and dispatches it to the bound device agent by
registry ID (`Jido.Signal.Dispatch`; the routing table comes from the manifest
bindings). The device agent's `signal_routes` map that signal to a state-sync
action. When the change is meaningful, the same action emits
`dobby.device.state_changed` with a dispatch list of two targets: the Phoenix
PubSub topic that feeds the thread and cards, and DobbyAgent's world model
(§6.3). One event stream, two consumers.

Jido's Sensor concept was considered for the client and set aside: a sensor
emits to one configured agent, and the client fans out per entity. It stays a
plain supervised process that speaks Jido signals.

The division of knowledge is unchanged:

```text
ThermostatAgent knows:      set_temperature → climate.set_temperature
HomeAssistant.Client knows: encode/send/reconnect/authenticate the HA message
Home Assistant knows:       how to reach and operate the physical thermostat
```

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

V1 capabilities, as the model sees them:

- `thermostat_get_status`
- `thermostat_set_temperature`

Only the second is a device *action*. A read carries no domain validation and
nothing to decide, so the read tool answers directly from device-agent state;
adding a `get_status` action for it would be a no-op existing only to make two
lists match. Device agents get signal routes for their effectful actions and
for HA state sync, and nothing else. `Dobby.DeviceAgent.tools/0` is what a
device type advertises; it is not required to mirror its action list.

`set_temperature` validates against the intersection of the entity's discovered
envelope and the configured household range (§4.3), then returns the `HACall`
directive for `climate.set_temperature` — or whatever mapping the device's
profile supplies instead. A setpoint outside that range is an `:ok` return, not
an error: the agent successfully decided "no", and the refusal travels back to
the model as an observation it must account for in its reply. Mode changes,
schedules, holds, and recovery behavior wait until the basic agent works with
the installed thermostat.

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

For “set the main thermostat to 70,” spoken by Greg in the web UI:

1. Phoenix sends `%Utterance{speaker: "greg", channel: :web, text: ...}` to
   DobbyAgent; the request pipeline injects roster, device snapshot, and
   speaker tag.
2. The model calls the tool `thermostat_set_temperature(device:
   "thermostat:main", temperature_f: 70)`.
3. The tool's action validates its arguments and dispatches to ThermostatAgent.
4. ThermostatAgent validates the target temperature and returns the `HACall`
   directive; its `DirectiveExec` hands it to the shared HA client.
5. The client sends `climate.set_temperature` to HAOS; HA's integration talks
   to the physical thermostat.
6. The tool result — accepted, target 70 — returns to the model, which
   composes the streamed reply.
7. HA publishes the changed `climate.*` state; the client dispatches it to
   ThermostatAgent, which updates its state and emits
   `dobby.device.state_changed` to the thread, the cards, and DobbyAgent's
   world model.

For “which endpoints are offline,” the model calls `wifi_get_status` per
configured endpoint; each answer comes straight from device-agent state, and
the model composes one summary. No HA round trip occurs.

Several tool calls in a single model turn execute **sequentially, in one
process**. The work still lands on separate device agents — three tools mean
three agent processes doing their own validation — but the runner calls each
and waits before starting the next, so latency is the sum and not the maximum.
This is free while reads are in-memory (measured: three calls 76 µs apart). If
a device type ever needs a slow read, the answer is one batch tool that fans
out internally, not a change to the loop. Note also that `HACall` directives
drain *after* the agent's command completes, so the HA side is not serialized
behind the tool loop at all — a write tool returns "accepted" without waiting
on Home Assistant.

At 20:00 on a weekday, the “weeknight heat” schedule fires (§9): cron signal →
SchedulerAgent dispatches the stored `set_temperature` action to
ThermostatAgent → `HACall` → HA. No model call occurs anywhere in that trace;
the thread shows a system line.

Direct controls in Phoenix bypass the LLM but follow the same lower path:

```text
Phoenix control → ThermostatAgent → HA client → HAOS → thermostat
```

This no-LLM path is load-bearing: it is the test surface for the deterministic
layer and the fallback during model outages.

## 9. Schedules

“Dobby, I always want the thermostat at 70 by 8pm on weekdays.” The defining
feature of a house that feels run rather than merely controllable — and in
this design, the model's job is authoring, never firing.

A schedule is one Postgres row — the repo's first table:

```elixir
%Dobby.Schedules.Schedule{
  id: 3,                             # integer: a model reads it back reliably
  label: "weeknight heat",           # unique, case-insensitively
  cron: "0 20 * * 1-5",
  timezone: "America/New_York",      # from the home manifest, per row
  target: "thermostat:main",
  action: "set_temperature",
  args: %{"temperature_f" => 70.0},
  enabled: true,
  created_by: "greg",
  created_via: :conversation          # or :admin
}
```

The typed action is three columns rather than one nested map: the admin
dashboard filters by device, and `target` is how a stale schedule is found when
a device leaves the manifest. Only `args` stays a map, because its shape
belongs to the device action.

`SchedulerAgent` loads enabled rows at boot and registers one Jido `Cron`
directive per schedule; creating, editing, pausing, or deleting a schedule
re-registers (`CronCancel` + `Cron`). The cron signal routes to an action that
dispatches the stored device action down the same typed path used by tools and
cards — full device-agent validation included. Firing is deterministic and
model-free; the test rig asserts that the firing trace contains zero model
calls.

Two authoring surfaces edit the same rows: DobbyAgent's schedule tools (§6.2)
and the admin dashboard's scheduler CRUD (§10). A firing posts a system line
to the thread and full detail to the activity log.

**What a device can be scheduled to do is the device type's own declaration.**
`Dobby.DeviceAgent.scheduled_actions/0` names them, keyed by what a row stores;
`%{}` is a complete answer and means a schedule aimed at that device is refused
when it is asked for. This is deliberately narrower than `signal_routes` — an
agent routes `ha.state_changed` too, and nothing should be able to schedule
that. It also keeps §4.2's extension contract intact: `Dobby.Schedules` holds
no list of device types, so a new one brings its own schedulable surface, and
the `<house>` block advertises it to the model per device rather than baking it
into a tool schema that is fixed at compile time.

**Validation splits three ways, and the split is the design.** *Shape* — is
this a cron expression — is the changeset. *The house* — does this device
exist, does it accept this action, are these its arguments — happens at
authoring time against the running manifest. *Policy* — is 85° inside this
household's range, is the thermostat even available — stays in the device agent
and is applied **at fire time**. That last one is not laziness: the accepted
range is discovered from the hardware (§4.3), so checking it at authoring time
would reject a schedule written before the thermostat first reported. The
honest consequence is that a schedule can be accepted in conversation and
refused at eight o'clock; the refusal is announced on `dobby.schedule.fired`
rather than swallowed.

**Timers are compared against the rows, never against remembered intent.**
`SchedulerAgent` keeps no record of what it registered. `unregistered/0` asks
the rows and the live job table, which is the only question worth answering,
and `sync/0` blocks until the two agree — Jido executes directives from a drain
loop it kicks off with `send(self(), :drain)`, so they are still queued when the
call that produced them replies, and a failed `Cron` registration is swallowed
by design (`on_failure: :keep`) and merely logged. Without that barrier a
schedule that never fires looks exactly like one that does.

**This reverses the original design's §7.5**, which ruled that schedules
execute in HA and the agent only authors them. Reversed 2026-08-13, Greg
approving: the household needs to *see* schedules, which our own rows give the
admin dashboard for free; authoring HA automations over its API is the genuinely
hairy surface; and execution here is equally deterministic — the principle that
mattered, "deterministic below, probabilistic above," survives intact. The
accepted cost: schedules miss if Dobby is down. Same box, same UPS — if the
system's down, the system's down.

Oban was named here as the drop-in fallback if Jido's `Cron` directive proved
unreliable across restarts. It is not needed: `Cron` registers from an ordinary
`use Jido.Agent` action, its tick casts our own `%Jido.Signal{}` back through
normal routing verbatim, and restarts are not a question it has to answer —
nothing about a schedule lives in a process. Every timer is rebuilt from the
rows at boot, so a restart cannot leave a stale timer or lose a live one, and
Jido's own cron persistence is simply unused. `crontab` and `time_zone_info`
come in with Jido, so there is no new dependency either way.

Conflict behavior in v1 is dumb and honest: schedules fire regardless of
manual changes, and the last write wins. Mediation ("you set it manually an
hour ago — skip tonight?") is a later behavior sitting on the awareness seam.

## 10. Phoenix surface and persistence

### 10.1 The thread

The household surface is one shared, persistent, Discord-like thread — the
transcript table rendered, with full scrollback. Speaker messages appear
attributed; voice utterances will land inline with a channel marker; Dobby is
a participant that answers and can eventually speak unprompted.

Actuations post **system lines**: muted one-liners whenever anything changes
the house through any path — a Dobby tool call, a card tap, a schedule firing,
or an external change observed via HA (“· thermostat set to 70 — schedule
'weeknight heat'”). Passive observations (an endpoint going offline) stay on
the cards and in the activity log. The rule: the thread records interventions;
the admin records everything.

### 10.2 Identity

A first-visit “Who's this?” prompt names the browser; a device cookie pins it.
Identity is personalization and attribution only, never permissions. MAC-based
identification was considered and rejected: browsers cannot see their own MAC,
the server could only ARP-sniff it, and modern mobile OSes randomize MACs
per-network. ARP lookup may later serve as an auto-recognition *hint* for
known devices, never as the identity itself.

### 10.3 Cards

A card for the thermostat (status plus a direct `set_temperature` control) and
one per Wi-Fi endpoint, updating live from `dobby.device.state_changed` over
PubSub. Card controls hit device agents with no LLM involved.

### 10.4 Admin dashboard

Open to any household member, per flat trust:

- the activity feed — every request, tool call, result, and state change;
- scheduler CRUD over the same rows the model authors;
- agent and HA-connection health.

### 10.5 Streaming and persistence

Streaming plumbing is ours to build: a task per request iterates Jido AI's
request event stream and republishes deltas to the LiveView over PubSub. Jido
provides the events, not the LiveView wiring.

Postgres stores speakers, the transcript, schedules, and the activity log.
Device state remains owned by HA and is rebuilt in the agents after restart;
DobbyAgent rehydrates its recent conversation window from the transcript.

## 11. What we are deliberately not designing yet

- room and space agents;
- a HouseCoordinator;
- generic effects and plans;
- standing policies and policy authoring;
- proactive behavior (announcements, alerts) — noting that the awareness seam
  in §6.3 is where it will attach;
- schedule conflict mediation;
- per-user private conversation threads;
- voice, speaker identification, Telegram, cameras, Sonos, and a broad
  dashboard;
- presence inference;
- workflows, scenes, and multi-device transactions;
- automatic device discovery or dashboard editing of `home.exs`;
- multiple houses;
- local model hosting.

These remain possible. None is allowed to shape the first implementation until
the thermostat and Wi-Fi agents work through both direct Phoenix controls and
the DobbyAgent.

## 12. Build order

Software no longer waits on hardware: everything in Phase A runs against a
fake HA client at the one honest boundary, so the Jido mechanics are proven
before the server exists. Phase B can proceed in parallel.

### Phase A — software against the test rig

1. **Scaffold and rig.** — *built.* Mix project with jido/jido_ai, the real
   agent modules, manifest bootstrap, and `FakeHA` at the client boundary. It
   records every executed `HACall` and injects `state_changed` events —
   including in response to commands, which is what makes the physical confirm
   loop real in tests rather than assumed. Replay tests script the model's
   turns; a second tier runs the same scenarios against a real model with cost
   and latency recorded.

   Two corrections to how this was imagined. The trace collector cannot order
   events across sources: Jido's signal events and Dobby's `HACall` event carry
   an emitter timestamp, `jido.ai.llm.start` and `jido.ai.tool.start` carry
   none, and a merged ordering built from that mix is plausible and wrong
   (measured: an `HACall` sorting ahead of the model turn that caused it). So
   `Dobby.Trace` promises per-source sequences and counts, and cross-source
   ordering is asserted with `assert_receive`, which is a real happens-before.
   And because the agents are started by the application supervisor rather than
   by the test, scripts must be threaded explicitly through the ask —
   `expect_react`'s registry lookup keys on the process group leader.

   The replay tier must be unable to reach a real model. Jido AI treats "no
   script matched" as permission to call the provider, so a forgotten script is
   an ordinary mistake with a billable outcome; every provider is pointed at a
   closed port in the test environment, and the eval tier lifts that
   deliberately.
2. **DobbyAgent.** — *built.* Tools, world model, prompt architecture, soul.
   Scenarios proven replay-first then live: “turn the thermostat to 70”; terse
   “thermostat 72”; “make it cozy” (judgment or clarification); two thermostats
   + ambiguous “thermostat 72” (must clarify, zero HACalls); “set the
   thermostat to 69 and check all the endpoints”; a clarification answered a
   turn later (“the downstairs one”); and two scenarios the house cannot serve
   at all — a room it does not model, a capability it does not have.

   Still open here: two speakers issuing conflicting setpoints (last write
   wins, attributed); an unavailable device answered honestly end to end
   through the model; and a state-change injection then “what's the thermostat
   at?”.
3. **Scheduler.** — *built, less the admin CRUD, which arrives with the
   dashboard in step 4.* Schedule rows (the repo's first migration),
   `SchedulerAgent` on the `Direct` strategy, four authoring tools, and firing
   tests including the zero-model-calls assertion.

   "Simulated clock" turned out to mean two things, and separating them is what
   made the tests fast and honest. Jido's cron jobs read the system clock and
   arm `Process.send_after`; there is nothing to inject. So *schedule
   semantics* — what `0 20 * * 1-5` means asked on a Saturday, what it does on
   a spring-forward morning — are answered by a pure `next_fire/3` that takes
   `from` as an argument, and *firing* is driven by casting the signal the
   timer casts, built by the same function that registers it. One test then
   lets the real timer do the work end to end, using a six-field
   seconds-resolution expression so that costs a second rather than a minute —
   which is the only reason six-field expressions are accepted at all.

   Three contract findings, each of which had already broken something.
   Jido merges an action's state update into agent state with a **deep** merge,
   so a map field cannot be cleared or pruned by assigning it — which is why
   the scheduler keeps no record of what it registered. `:map` in a tool schema
   is the sibling of the union type in §6.2: it renders as `"object"`, which is
   right, and NimbleOptions reads it as `{:map, :atom, :any}`, so the object a
   model sends is rejected for having string keys before `run/2` is reached.
   And per-request tool context — how `create_schedule` learns who asked without
   the model supplying it — is the `:tool_context` option, not `:context`.
4. **Phoenix surface.** The thread with streaming and system lines, identity,
   cards, admin dashboard — all against FakeHA.

### Phase B — hardware (parallel)

5. **Server and HAOS.** Proxmox on the mini-server, HAOS VM from the official
   image, LAN bridge, stable DHCP lease, HA onboarding.
6. **Inventory.** Identify the installed thermostat integration; configure two
   or three fixed endpoints via HA Ping; record actual entity IDs, states,
   attributes, and actions — the entity and device registries give most of this
   directly (§4.3) — and write the real instances into `config/homes/foo.exs`.

### Phase C — integration

7. **Real client.** Debian services VM, Postgres, deploy (§2.4); swap FakeHA for the
   real WebSocket client; prove direct deterministic actions against the real
   house, including invalid-temperature and unavailable-device behavior.
8. **Live.** DobbyAgent and schedules against the real house at
   `dobby.local`; record failures, cost, and latency. The next ingress, device
   behavior, or abstraction is chosen from actual use.

## 13. Current decisions

1. Phoenix is the first ingress and household interface; later ingress channels
   feed the same DobbyAgent as new `channel` values on the same envelope.
2. Jido supplies the agents, runtime, actions, signals, and directives; Jido AI
   supplies the ReAct strategy, tool adaptation, and model access.
3. DobbyAgent is one long-running ReAct agent holding the shared household
   conversation and a signal-fed world model; it acts only through the closed
   tool set and composes replies from real tool results.
4. Every utterance carries `speaker` and `channel` from the first build.
   Identity personalizes; it never gates. Device identity is cookie-pinned
   with a chosen name, never MAC-derived.
5. The household surface is one shared persistent thread; actuations appear as
   system lines; the admin dashboard carries the full activity feed, scheduler
   CRUD, and health.
6. Schedules are Dobby-owned Postgres rows, authored conversationally by the
   model or in the admin, fired deterministically with no model call —
   reversing original-design §7.5 (2026-08-13).
7. Device agents are deterministic Direct-strategy Jido agents owning their HA
   bindings, state translation, allowed actions, validation, and HA command
   mapping via custom `HACall` directives.
8. One shared HA client owns authentication, transport, subscriptions, and
   reconnect behavior, and speaks to agents only in signals.
9. The build is rig-first: a fake HA client at the one honest boundary, replay
   tests scripting the model, and eval scenarios against a real model — before
   any hardware exists. Hardware proceeds in parallel.
10. HAOS runs in its own Proxmox VM and owns physical device integration and
   observed state.
11. V1 includes one thermostat, a few read-only Wi-Fi endpoints, and the
   scheduler.
12. Reusable agent modules live in `Dobby.DeviceAgents`; concrete homes and
   device instances are declared in `config/homes/*.exs` and read at runtime;
   the future extraction target for shared device behavior is a `Jido.Plugin`.
13. Vendor integration is an HA concern and a profile lookup key (§4.3), not
   the device-agent class hierarchy. Device capabilities are discovered from
   HA; the manifest only narrows them to household policy.
14. The first implementation optimizes for a working vertical slice, not a
   general smart-home ontology.
15. Dobby is one Phoenix application, not an umbrella, deployed as an OTP
   release under `/opt/dobby` and supervised by systemd.
16. Configuration on the box — the home manifest, the soul, and the secrets
   file — is read at boot from outside the release, so changing the house or
   who answers in it is a restart rather than a rebuild.
17. Dobby's voice lives in `config/soul.md` and is editable without a release;
   the rules that keep him honest live in code and are composed last, so
   doctrine wins any conflict with personality (§6.6).
18. The model's tool list is declared as a compile-time literal library and
   narrowed to the configured house per request. This is forced by
   `Jido.AI.Agent`, whose macro options cannot be computed (§6.1).
19. Per-turn context is injected as its own message ahead of the utterance,
   never appended to it, so the raw utterance stays last (§6.3).
20. The rig has two tiers and they answer different questions. Replay pins the
   emitted pattern and must be incapable of reaching a provider. Eval asks
   whether a real model exercises judgment, and it is the only tier that can
   catch a tool contract that lies to the model, a prompt that permits
   fan-out on an ambiguous request, or a model echoing input framing into
   user-visible output — all three of which it did catch. Rotating models is
   itself a test; a single-model eval hides model-specific defects.

## Sources

- [Jido agents](https://jido.run/docs/concepts/agents)
- [Jido agent runtime](https://jido.run/docs/concepts/agent-runtime)
- [Jido actions](https://jido.run/docs/concepts/actions)
- [Jido signals](https://jido.run/docs/concepts/signals)
- [Jido directives](https://jido.run/docs/concepts/directives)
- [Jido plugins](https://jido.run/docs/concepts/plugins)
- [Jido AI agent](https://jido-ai.hexdocs.pm/Jido.AI.Agent.html)
- [Jido AI context](https://jido-ai.hexdocs.pm/Jido.AI.Context.html)
- [Jido AI tool adapter](https://jido-ai.hexdocs.pm/Jido.AI.ToolAdapter.html)
- [ReqLLM](https://hexdocs.pm/req_llm)
- [Home Assistant OS virtual-machine installation](https://www.home-assistant.io/installation/alternative/)
- [Home Assistant WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)
- [Home Assistant climate platform](https://www.home-assistant.io/integrations/climate/)
- [Home Assistant NuHeat integration](https://www.home-assistant.io/integrations/nuheat/)
- [Home Assistant Ping integration](https://www.home-assistant.io/integrations/ping/)
- [Home Assistant device trackers](https://www.home-assistant.io/integrations/device_tracker/)
- [Home Assistant Google Wifi integration](https://www.home-assistant.io/integrations/google_wifi/)
