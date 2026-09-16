# Dobby

A house elf for your Home Assistant.

**Status:** 0.2.0, released 2026-09-16, is the current release. Linux
tarballs for amd64 and arm64 are on the
[releases page](https://github.com/mhyrr/dobby/releases), what is in them is
in [CHANGELOG.md](CHANGELOG.md), and installing one is the guide's
[box chapter](https://mhyrr.github.io/dobby/box.html#install). It has run on
a Debian 12 VM against a local Home Assistant, not yet on a box in a house.

Dobby is a household agent. Everyone in the house, kids included, talks to
it in one shared thread, and it answers by doing things: reading the
thermostat, dimming a light, starting the vacuum, setting a schedule for
eight o'clock. It does what you said, says what it did, and asks when it is
not sure.

Underneath are two layers. A deterministic
layer of device agents owns every fact and every action. Above it sits a
language model that can act only through the closed set of tools those
agents offer. The model never touches Home Assistant. It reports what it 
commanded and the house reports what actually happened.

## The guide

**[mhyrr.github.io/dobby](https://mhyrr.github.io/dobby/)** is the user's
guide: what you need, the house file section by section, running it and
putting it on the Wi-Fi, an always-on box, living with it, growing the house,
sending your own agent at it over MCP, how it works, and developing. Every
page is written from a walk somebody took, and says so where one has not
been taken yet. The source is `docs/`, hand-written HTML served as committed.

[Appliance research and setup](docs/appliance-research.md) covers Bosch,
Wolf, Sub-Zero, and NuHeat, plus the wider integration landscape. Dishwasher,
oven, refrigerator, washer, dryer, coffee maker, wine cooler, ice maker, cooktop,
and microwave status use explicit sensor bindings. Water heater, humidifier,
dehumidifier, air purifier, and range hood controls use standard HA interfaces.
Floor heat uses `thermostat`; a standalone freezer uses `refrigerator`.
[Appliance contracts](docs/appliance-contracts.md) lists the supported readings,
controls, and refusal rules. Makes and models belong in Home Assistant.

## Running it

You need a reachable Home Assistant, PostgreSQL, and an
[OpenRouter](https://openrouter.ai/) account. Dobby speaks to one model
provider, and every model it can answer with is served through OpenRouter, so
the account is a requirement rather than one choice among several.

```sh
mix setup
cp config/homes/example.yaml config/homes/my-house.yaml
# edit it: your HA's address, your devices

export DOBBY_HA_URL=http://homeassistant.local:8123
export DOBBY_HA_TOKEN=...            # HA → your profile → Security → long-lived tokens
export OPENROUTER_API_KEY=...        # one key; `system.model` selects the model

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
