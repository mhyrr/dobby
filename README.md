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

## The guide

**[mhyrr.github.io/dobby](https://mhyrr.github.io/dobby/)** is the user's
guide: what you need, the house file section by section, running it and
putting it on the Wi-Fi, an always-on box, living with it, growing the house,
sending your own agent at it over MCP, how it works, and developing. Every
page is written from a walk somebody took, and says so where one has not
been taken yet. The source is `docs/`, hand-written HTML served as committed.

## Running it

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

`mix dobby.ha.verify` proves the authenticated state sync before you trust an
evening to it. Then `/` is the thread, `/house` the cards, `/admin` the
maintainer's room, and `/mcp` the door for an agent that is not Dobby.

## Developing

`mix test` runs everything against a fake Home Assistant that lives in the
repo: no HA, no network, no model calls. The local rig with a real HA and
virtual devices, the two test tiers, and Tidewave are in the guide's
[Developing](https://mhyrr.github.io/dobby/developing.html) chapter.

The design record lives in [DESIGN.md](DESIGN.md) (the surface) and
[dobby-design-jido.md](dobby-design-jido.md) (the architecture).
