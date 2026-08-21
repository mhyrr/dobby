# Setting up Dobby in your own house

This is the household path: your machine, your Home Assistant, your devices.
The developer path — a local HA in a container, virtual entities, no hardware
— is [local-ha.md](local-ha.md).

The destination: a talking Dobby that the whole household reaches at
`http://dobby.local/`, described by two files you own — `home.yaml` and
`soul.md` — with `mix dobby.ha.verify` proving the wiring before you trust an
evening to it.

## What you need

- **Elixir** (1.19+) and **PostgreSQL**. `mix setup` installs dependencies and
  creates the database.
- **A Home Assistant you can reach**, and a long-lived access token for it:
  in HA, open your profile → **Security** → **Long-lived access tokens** →
  create one. It is shown once; put it straight into your environment.
- **A model API key.** Unset, Dobby uses the committed default, which needs an
  Anthropic key; `system.model` in `home.yaml` swaps providers without a
  rebuild — any `provider:model` ReqLLM speaks.

## The house file

Copy the example and make it yours:

```sh
cp config/homes/example.yaml config/homes/my-house.yaml
```

The example explains itself — every section carries the comment you would
otherwise look up here. The shape:

- **`house:`** — what the house contains. Its name and timezone, where Home
  Assistant is, and one entry per device Dobby manages. Each device has a
  stable `id` (convention `type:place`), a `type` (one of `thermostat`,
  `light`, `vacuum`, `wifi_endpoint`), the `name` and `aliases` the household
  actually says out loud, `bindings` naming the HA entity behind each part,
  and optional `settings` — household policy, like the setpoint range anyone
  is allowed to ask for. Policy can narrow what the hardware allows, never
  widen it.
- **`system:`** — the box Dobby runs on rather than the house it looks after:
  `model`, `port`, `lan`, `hostname`. All optional, and an exported
  environment variable always wins over the file, so a one-off experiment
  never means editing it.

Two rules keep the file shareable and honest:

- **Credentials are references, never values.** `token: env:DOBBY_HA_TOKEN`
  names a variable; Dobby resolves it at boot and refuses to start with a
  sentence naming exactly what is missing.
- **Dobby writes this file too.** Edits made on `/house` and `/admin`, and
  devices an agent adds — Dobby's own or yours over MCP — all land in the
  same YAML through one writer. Hand edits are welcome; they take effect
  when Dobby restarts. Keep it a data file — a house described in `.exs` still boots, but Dobby will
  not write one, and the editing surfaces will say so.

Entity ids live in HA under **Settings → Devices & services → Entities**. Use
them exactly as HA names them.

## The soul

`config/soul.md` is who is answering: voice, manners, what Dobby cares about.
Edit it like the prose it is. `DOBBY_SOUL` points somewhere else if you keep
yours outside the repo.

## Verify, then run

```sh
export DOBBY_HA_URL=http://homeassistant.local:8123
export DOBBY_HA_TOKEN=...
export ANTHROPIC_API_KEY=...

DOBBY_HOME_MANIFEST=config/homes/my-house.yaml mix dobby.ha.verify
```

Verify boots the real client against your HA and prints every device's
snapshot once the initial state sync lands — `available: true` with readings
proves connection, authentication, subscription, routing, and interpretation
in one line per device. `--round-trip` goes further and drives a thermostat
through a one-degree setpoint change and back; it aims at the first
thermostat in the manifest unless you name one, and it is a real change to
whatever that entity controls, so name a virtual one if you have any doubt:

```sh
mix dobby.ha.verify --round-trip thermostat:demo
```

Then:

```sh
DOBBY_HOME_MANIFEST=config/homes/my-house.yaml mix phx.server
```

In development a gitignored `.env` (see `.env.example`) saves re-exporting all
of this per shell; the real environment still wins, and `mix test` ignores
every one of these variables by design.

## The whole household

`system.lan: true` (or `DOBBY_LAN=1`) binds every interface and advertises the
machine as `dobby.local` for as long as the server runs, so every phone and
tablet on the Wi-Fi can open it. Pair it with `port: 80` so the address is
just `http://dobby.local/`. Flat trust, deliberately: the Wi-Fi password is
the boundary, and `/admin` is a room in the house, not a privilege level.

## Growing the house

Four ways, one file:

1. **Say it.** "What does Home Assistant have that we don't?" — Dobby reads
   the unclaimed entities and proposes a device entry. Nothing changes until
   somebody says yes; a proposal is reported as proposed, an applied change
   as applied, and the house restarts into its new shape. It scales to the
   whole house: name everything you have and Dobby proposes the lot as one
   list — one yes adopts everything on it, and anything Home Assistant does
   not show, Dobby says it cannot see rather than guessing.
2. **`/house`.** Every device card has `edit` and `remove`, and the foot of
   the list has `add a device`. The form's fields come from the device type's
   own schema — a refused value is refused in the same words the file would
   use, naming the field.
3. **The file.** Edit `home.yaml`, restart Dobby.
4. **Send your own agent.** Any MCP client holding a minted token can do
   everything the first way does — see
   [Bring your own agent](#bring-your-own-agent-mcp).

After any of them, devices read `NOT KNOWN` for a moment until Home Assistant
speaks. That is honesty, not breakage — the house learning what it has — and
the first state sync fills it in.

## Bring your own agent (MCP)

You do not have to do the setup by hand, and you do not have to do it in
Dobby's own chat. Dobby serves its tools over MCP at `/mcp` — the same
modules, the same schemas, the same refusals its own model gets — so the AI
you already use can do the work.

1. **Mint a key.** On `/admin`, under the system section, mint a token with a
   label naming the agent that will hold it ("Ann's laptop"). The token is
   shown once and never again; the label is what every call made with it will
   be logged under. `revoke` closes the door without ceremony.
2. **Connect your agent.** For Claude Code:

   ```sh
   claude mcp add --transport http dobby http://dobby.local/mcp \
     --header "Authorization: Bearer <the token>"
   ```

   Any MCP client that speaks streamable HTTP connects the same way.
3. **Tell it what you have.** "Dobby at dobby.local runs my house. I have a
   thermostat, three lights, and a robot vacuum, all on Home Assistant — set
   them up." The agent discovers what HA sees, proposes each device, and
   confirms them into `home.yaml`; the house restarts into its new shape and
   the cards fill in as HA speaks.

The trust is the house's own, stated plainly: a token-holder speaks for the
household, the way anyone with the Wi-Fi password does on the surfaces. That
is why the tokens live on `/admin` and every key carries a name — the record
of who asked is the token's real job.

## Running as an installed service

A release looks for the two files at `/opt/dobby/config/home.yaml` and
`/opt/dobby/config/soul.md` — no environment variables needed for either.
`DATABASE_URL` and `SECRET_KEY_BASE` are the operator's side of the line and
stay in the environment; see `config/runtime.exs`.
