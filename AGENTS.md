# Dobby

A household agent for Home Assistant. Everyone in the house talks to it in one
shared thread, and it answers by doing things. One Phoenix application, not an
umbrella: Elixir 1.18, Phoenix 1.8, LiveView 1.2, PostgreSQL, Jido 2.3.

| Read this | For |
|---|---|
| `README.md`, `PRODUCT.md` | What Dobby is, who it is for, what it promises |
| `docs/design/dobby-design-jido.md` | The architecture and its numbered decisions. `@moduledoc`s cite it (`design §4.2`). A record, not a spec: read the code for what is true and this for why |
| `DESIGN.md` | The surface. Binding, and it overrides any generic UI guidance |
| `docs/*.html` | The user's guide, published at https://mhyrr.github.io/dobby/ |

## The line the codebase is built around

Two layers. The deterministic layer (device agents, the Home Assistant client,
schedules, the direct control path) owns every fact and every action. The
language layer is one long-lived `Jido.AI` ReAct agent that acts only through
the closed set of tools those device agents advertise. What follows is not
negotiable:

- **The model never touches Home Assistant.** A tool calls a device agent, the
  agent returns a `Dobby.Directive.HACall`, the runtime performs it. A path
  from the language layer to the network breaks the product.
- **The model never does arithmetic.** LLMs extract, code computes.
- **The model reports what it commanded, never what it observed.** A write
  returns acceptance; physical confirmation arrives later as a state change.
  The reply may phrase an accepted command as done, because the house writes
  HELD or NOT KNOWN beneath it if the command did not arrive (decisions 24,
  27). A reading the model never took stays impossible.
- **Ambiguity is a refusal to act, not a licence to act broadly.** "The
  thermostat" in a house with two is a question.
- **The direct control path is first-class.** A card tap reaches the device
  with no model involved. It is what the house does when the model is down.
- **Validation lives in the device agent.** The tool layer adds transport and
  nothing else.

## Where things live

```text
lib/dobby/
  device_agent.ex        The contract every device type implements
  device_agents/         The library: every device type and its actions
  home_config/types.ex   The registry of types
  home_assistant.ex      The boundary. `impl/0` picks Fake or the real client
  agent.ex               Dobby.DobbyAgent: the ReAct agent and its prompt
  tools/                 The model's closed tool set, one Jido.Action each
  controls.ex            The direct control path
  schedules.ex           Dobby-owned rows, fired with no model call
  command_events.ex      The confirmation seam: expectations and refusals
  interventions.ex       System lines: what somebody did, however they did it
  home_config.ex         home.yaml in both directions; Writer is the one write path
  mcp/                   The door for someone else's agent, same closed tools
lib/dobby_web/live/      thread_live `/`, house_live `/house`, admin_live `/admin`
lib/dobby_web/components/flap.ex   The split-flap: a state word, never a bare number
```

## Adding a device type

One module implementing `Dobby.DeviceAgent` plus its actions. Register it in
`Dobby.HomeConfig.Types`, then add its tools to the literal declaration in
`Dobby.DobbyAgent`: Jido resolves `tools:` at macro-expansion time, so the list
cannot be computed. No central switch changes; a `case` over device types
somewhere central is the design being lost.

Every registered type needs `test/dobby/device_agents/<module>_test.exs`
invoking `device_agent_contract`. `LibraryContractTest` fails without it and
names the missing file. The contract requires `arrivals:` triples for every
writable attribute, because Home Assistant echoes a value at the entity's own
precision or notch, and one service call can move several of Dobby's
attributes at once. Find out what the integration actually sends back, from
its source, before writing `command_arrived?/2`.

## The Home Assistant boundary

`Dobby.HomeAssistant.impl/0` defaults to `Dobby.HomeAssistant.Fake`; the real
client is opt-in through config, which is why the suite runs with no HA and no
network. Inbound attribute maps carry string keys, because that is their shape
on the wire; a bare `:map` in a Jido action schema means atom keys to
NimbleOptions. `HACall` executes asynchronously: the tool has already returned
"accepted" before HA hears anything.

## The house file and the soul

`config/homes/*` is what the house contains; `config/soul.md` is who answers.
Both are read at boot from outside the release. Credentials never appear in
either: the manifest says `env:DOBBY_HA_TOKEN`. `.yaml` is canonical because
the audience speaks `configuration.yaml` and a machine can write it back; the
rig manifest stays `.exs` because tests build manifests by hand. Anything that
writes the house goes through `Dobby.HomeConfig.Writer`. Doctrine beats
personality: `soul.md` is editable without a release, and the rules that keep
Dobby honest live in code and are composed last.

## Testing

```sh
mix test                           # replay tier: no HA, no network, no model calls
DOBBY_EVAL=1 mix test --only eval  # eval tier: real inference, real money
```

`config/test.exs` gates the provider on `DOBBY_EVAL`, not the ExUnit tag.
`--include eval` without the variable points every provider at a dead loopback
address; with the variable it lifts that guard over the whole replay suite,
which is the billable accident the guard exists to prevent. Use `--only`.

If a fixture seeds what production builds, the test is lying. A test about
whether something was somebody's doing reads the thread, not the flag: issue a
real command through the rig and assert the system lines the thread shows.

## Commands

```sh
mix precommit                 # compile --warnings-as-errors, unused deps, format, test
mix phx.server                # needs DOBBY_HOME_MANIFEST
mix dobby.ha.verify           # prove a real HA connection and initial state sync
mix reach.check --smells      # advisory review leads
bin/changelog                 # this branch's entry under CHANGELOG/unreleased/
```

`mix precommit` before calling anything done. In dev the server serves
Tidewave at `/tidewave/mcp` (loopback only).

## Conventions

- Commit messages are sentences about what changed for the house, not
  Conventional Commits.
- Every branch carries a changelog entry, in the same voice.
- Moduledocs explain why, and the alternative that was rejected.
- A broad `rescue` states why it is broad, at the rescue. `mix reach.check`
  flags the ones that do not.
- Never use `Mix.env()` to change runtime behaviour; it is a config value.
- Incidents and gotchas go to HIVE memory, not this file.

## Elixir traps the model still trips on

Lists have no index access (`Enum.at`, never `list[i]`). A rebinding inside
`if`/`case` is lost unless the block's result is bound. One module per file.
Structs do not implement Access (`struct.field`, not `struct[:field]`). No
`else if`: use `cond`. `String.to_atom/1` never on user input. Predicates end
in `?` and never start with `is_`. In HEEx, `{...}` in attributes and bodies,
`<%= %>` only for blocks in bodies, `<%!-- --%>` for comments, and
`phx-no-curly-interpolation` on any tag showing literal braces. The `elixir-*`
skills carry the rest.
