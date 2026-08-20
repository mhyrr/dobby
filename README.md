# Dobby

A house elf for your Home Assistant.

Dobby is a household agent: everyone in the house talks to it in one shared
thread, and it answers by doing things — reading the thermostat, dimming a
light, starting the vacuum, setting a schedule for eight o'clock. Underneath,
it is two layers with a hard line between them: a deterministic layer of
device agents that owns every fact and every action, and a language model
above it that can act only through the closed set of tools those agents
offer. The model never touches Home Assistant, never does arithmetic, and
never claims a room got warm — it reports what it commanded, and the house
reports what actually happened.

## The two files a household owns

Everything about *your* house lives in two files. Everything else is the
application's business.

| File | Holds |
|---|---|
| `home.yaml` | What the house contains: your Home Assistant, your devices, your household's policy. Start from [`config/homes/example.yaml`](config/homes/example.yaml). |
| `soul.md` | Who is answering: Dobby's voice and manners. Start from [`config/soul.md`](config/soul.md). |

Credentials are never written in either. `home.yaml` says `env:DOBBY_HA_TOKEN`
and Dobby reads the variable at boot, which is what keeps the file safe to
share, commit, or send to someone debugging your setup.

You can edit the house three ways, and they all end in the same file: open
`home.yaml` in an editor, use the forms on `/house` and `/admin`, or just tell
Dobby — "add the new thermostat as the dining room thermostat" — and confirm
what it proposes.

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
trust an evening to it. The full household path — token setup, every knob,
what the file's sections mean, serving the whole house at `http://dobby.local/`
— is in [docs/setup.md](docs/setup.md).

## The surfaces

- `/` — the thread. One conversation for the whole household, with the board
  above it showing the devices worth watching right now.
- `/house` — every device, its state, and what it can be asked; edit the
  house here.
- `/admin` — the maintainer's room: a live diagram of the house's mind, health,
  schedules, the box's own settings, and the full activity log. A room in the
  house, not a privilege level — the Wi-Fi password is the boundary.

## Developing

`mix test` runs everything against a fake Home Assistant that lives in the
repo — no HA, no network, no model calls, and no environment variable changes
any of that. To develop against a real local HA with virtual demo entities
(still no hardware), see [docs/local-ha.md](docs/local-ha.md).

The design record lives in [DESIGN.md](DESIGN.md) (the surface) and
[dobby-design-jido.md](dobby-design-jido.md) (the architecture).
