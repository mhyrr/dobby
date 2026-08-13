# Dobby — Simple Jido Design

**Draft v0.9 — August 2026**

**Status:** first build; supersedes v0.7/v0.8 after research against the Jido
2.x docs (jido 2.3.3, jido_ai 2.3.0) and the design session of 2026-08-13. The
original household vision remains in `dobby-design-original.md`.

Changes from v0.8: the household surface is one shared Discord-like thread
with system lines for actuations; device identity is cookie-pinned, not
MAC-based; Dobby owns schedules as Postgres rows authored conversationally and
fired deterministically — reversing the original design's rule that HA
executes all schedules (§9); an admin dashboard carries the activity feed and
scheduler; and the build order is test-rig-first, with hardware in parallel
rather than as a prerequisite.

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

## 2. Physical deployment

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
3. start one Jido agent instance for each device entry, registered in
   `Jido.Registry` under its Dobby ID;
4. start SchedulerAgent, which loads enabled schedules from Postgres (§9);
5. start DobbyAgent with a roster containing names, aliases, IDs, and the tool
   set derived from the configured agent modules;
6. configure the shared HA client with the entity-to-agent routing table derived
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
3. add one or more instances to `config/home.exs`;
4. restart Dobby.

The bootstrap automatically starts the instances, routes their HA entities, and
adds their actions to the DobbyAgent tool set. No central switch statement
changes.

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
    name: "dobby",
    model: :capable,                      # alias in config, swappable per §2.1
    tools: Dobby.Home.tools(),            # derived from configured agent modules
    system_prompt: ...,                   # house identity, rules, tone
    max_iterations: 5,
    streaming: true
end
```

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
pause_schedule(id) / resume_schedule(id) / delete_schedule(id)
```

Each tool is a thin `Jido.Action` whose arguments are validated against its
schema before it runs — malformed or unknown-device calls are rejected and the
error returns to the model as an observation, not an exception. Its `run/2`
dispatches to the target device agent through the registry and returns the
device agent's actual result to the model. Domain validation (the household
temperature range, device availability) still lives in the device agent; the
tool layer adds nothing but transport.

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
  of last-known device state. Each turn, the request pipeline (Jido AI's
  per-turn request shaping hook, with `Jido.AI.PromptBuilder` as fallback)
  injects the roster and current snapshot as tagged context on the user
  message — deliberately not the system prompt, to preserve prompt caching.

So the model always knows what devices exist, what state they were last in,
and who is speaking, before it decides whether to answer, clarify, or act.
The world model is also the seam future proactive behavior hangs off — the
signals already arrive; v1 simply does nothing with them beyond awareness.

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
mechanism instead of needing a schema branch. The price is two to three model
calls per actuating request instead of one; `max_iterations` caps the loop,
and Jido AI's quota and model-routing plugins are available knobs if cost ever
argues for them.

There is no separate parser, planner, coordinator, generic effect language, or
approval component in v1.

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

V1 actions:

- `get_status`
- `set_temperature`

`set_temperature` validates the configured household range and returns the
`HACall` directive for `climate.set_temperature`. Mode changes, schedules,
holds, and recovery behavior wait until the basic agent works with the
installed thermostat.

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

A schedule is one Postgres row:

```elixir
%Dobby.Schedule{
  id: ...,
  label: "weeknight heat",
  cron: "0 20 * * 1-5",              # timezone from the home manifest
  action: %{target: "thermostat:main", action: :set_temperature,
            args: %{temperature_f: 70}},
  enabled: true,
  created_by: "greg",
  created_via: :conversation          # or :admin
}
```

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

**This reverses the original design's §7.5**, which ruled that schedules
execute in HA and the agent only authors them. Reversed 2026-08-13, Greg
approving: the household needs to *see* schedules, which our own rows give the
admin dashboard for free; authoring HA automations over its API is the genuinely
hairy surface; and execution here is equally deterministic — the principle that
mattered, "deterministic below, probabilistic above," survives intact. The
accepted cost: schedules miss if Dobby is down. Same box, same UPS — if the
system's down, the system's down. If Jido's `Cron` directive proves unreliable
across restarts, Oban is the drop-in fallback: same rows, different timer.

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

1. **Scaffold and rig.** Mix project with jido/jido_ai, the real agent
   modules, manifest bootstrap, and `FakeHA` at the client boundary — it
   records every executed `HACall` in an ordered trace and injects scripted
   `state_changed` events. A trace collector captures all signals and
   directives. Replay tests script the model's turns (Jido AI's scripted-ReAct
   support) and assert on emitted patterns; a second tier runs the same
   scenarios against a real model, judged, with cost and latency recorded.
2. **DobbyAgent.** Tools, world model, prompt architecture. Scenarios to
   prove, replay first, then live: “turn the thermostat to 70”; terse
   “thermostat 72”; “make it cozy” (judgment or clarification); two
   thermostats + ambiguous “thermostat 72” (must clarify, zero HACalls); two
   speakers issuing conflicting setpoints (last write wins, attributed); “set
   the thermostat to 69 and check all the endpoints”; an unavailable device
   answered honestly; a state-change injection then “what's the thermostat
   at?” with no HA round trip.
3. **Scheduler.** Schedule rows, SchedulerAgent, authoring tools, admin CRUD.
   Simulated-clock firing tests, including the zero-model-calls assertion.
4. **Phoenix surface.** The thread with streaming and system lines, identity,
   cards, admin dashboard — all against FakeHA.

### Phase B — hardware (parallel)

5. **Server and HAOS.** Proxmox on the mini-server, HAOS VM from the official
   image, LAN bridge, stable DHCP lease, HA onboarding.
6. **Inventory.** Identify the installed thermostat integration; configure two
   or three fixed endpoints via HA Ping; record actual entity IDs, states,
   attributes, and actions; write the real instances into `config/home.exs`.

### Phase C — integration

7. **Real client.** Debian services VM, Postgres, deploy; swap FakeHA for the
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
   device instances are declared in `config/home.exs`; the future extraction
   target for shared device behavior is a `Jido.Plugin`.
13. Vendor integration is metadata and an HA concern, not the device-agent
   class hierarchy.
14. The first implementation optimizes for a working vertical slice, not a
   general smart-home ontology.

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
- [Home Assistant Ping integration](https://www.home-assistant.io/integrations/ping/)
- [Home Assistant device trackers](https://www.home-assistant.io/integrations/device_tracker/)
- [Home Assistant Google Wifi integration](https://www.home-assistant.io/integrations/google_wifi/)
