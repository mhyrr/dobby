# Dobby

A house elf for your Home Assistant.

Dobby is a household agent. Everyone in the house talks to it in one shared
thread, and it answers by doing things: reading the thermostat, dimming a
light, starting the vacuum, setting a schedule for eight o'clock.

Underneath are two layers with a hard line between them. A deterministic
layer of device agents owns every fact and every action. Above it sits a
language model that can act only through the closed set of tools those
agents offer. The model never touches Home Assistant, never does arithmetic,
and never claims a room got warm. It reports what it commanded; the house
reports what actually happened.

## The two files a household owns

Everything about *your* house lives in two files. Everything else is the
application's business.

| File | Holds |
|---|---|
| `home.yaml` | What the house contains: your Home Assistant, your devices, your household's policy. Start from [`config/homes/example.yaml`](config/homes/example.yaml). |
| `soul.md` | Who is answering: Dobby's voice and manners. Start from [`config/soul.md`](config/soul.md). |

Credentials never appear in either file. `home.yaml` says
`env:DOBBY_HA_TOKEN` and Dobby reads the variable at boot. The file stays
safe to share, commit, or send to someone debugging your setup.

You can edit the house four ways, and they all end in the same file. Open
`home.yaml` in an editor. Use the forms on `/house` and `/admin`. Tell Dobby
— "add the new thermostat as the dining room thermostat" — and say yes to
what it proposes. Name everything you have and it takes the whole house in
one breath. Or let your own AI do the same through the MCP door, with a
token minted on `/admin`.

## Running it

You need Elixir, PostgreSQL, a Home Assistant you can reach, and an API key
for a model provider.

```sh
mix setup

cp config/homes/example.yaml config/homes/my-house.yaml
# edit it: your HA's address, your devices

export DOBBY_HA_URL=http://homeassistant.local:8123
export DOBBY_HA_TOKEN=...            # HA → your profile → Security → long-lived tokens
export ANTHROPIC_API_KEY=...         # or any provider ReqLLM speaks; see `system.model`

DOBBY_HOME_MANIFEST=config/homes/my-house.yaml mix dobby.ha.verify
DOBBY_HOME_MANIFEST=config/homes/my-house.yaml mix phx.server
```

`mix dobby.ha.verify` proves the connection and the round trip before you
trust an evening to it. The full household path is in
[docs/setup.md](docs/setup.md): token setup, every knob, what the file's
sections mean, and serving the whole house at `http://dobby.local/`.

## The surfaces

- `/` — the thread. One conversation for the whole household, with the board
  above it showing the devices worth watching right now.
- `/house` — every device, its state, and what it can be asked; edit the
  house here.
- `/admin` — the maintainer's room: a live diagram of the house's mind,
  health, schedules, the box's settings, the keys other agents hold, and the
  full activity log. A room in the house, not a privilege level — the Wi-Fi
  password is the boundary.

## Bring your own agent

Dobby serves its tools over MCP at `/mcp`, the same closed set its own model
uses. So an agent that is not Dobby can work the house: Claude Code on your
laptop, or whatever your household runs. Mint a labeled token on `/admin`
and hand it to your agent. Tell it what you have. It can discover what Home
Assistant sees, propose the devices, and confirm them into `home.yaml` — the
token is the household's own key. Every call it makes lands in the activity
log under the token's label. The recipe is in [docs/setup.md](docs/setup.md).

## Developing

`mix test` runs everything against a fake Home Assistant that lives in the
repo: no HA, no network, no model calls. No environment variable changes any
of that. To develop against a real local HA with virtual demo entities
(still no hardware), see [docs/local-ha.md](docs/local-ha.md).

The design record lives in [DESIGN.md](DESIGN.md) (the surface) and
[dobby-design-jido.md](dobby-design-jido.md) (the architecture).
