# The local Home Assistant rig

A real Home Assistant on this machine, with virtual entities and no
hardware. FakeHA stays the default for `mix test` and `mix phx.server`; this
instance is for exercising the real client — connection, authentication,
subscription, service calls — against actual protocol semantics.

Everything lives in `dev/home-assistant/`. The instance is disposable: its
runtime state is gitignored, and deleting it costs nothing but the two
commands to make another.

## Start it

Requires Docker. The official container image runs HA directly; no HAOS VM
is involved.

```sh
cd dev/home-assistant
docker compose up -d
```

First boot takes a minute or two. The instance listens on
`http://localhost:8123`, loopback only.

The configuration it runs is `configuration.seed.yaml`, mounted read-only
over the container's config file. It enables the `demo` integration, which
supplies the virtual entities — climate devices (`climate.hvac`,
`climate.heatpump`, `climate.ecobee`) and lights (`light.bed_light`,
`light.ceiling_lights`, `light.living_room_rgbww_lights`, ...) — with no
hardware behind them.

## Initialize it, once

```sh
mix run --no-start dev/home-assistant/onboard.exs
```

This creates the owner account, sets US customary units — Dobby's
temperature fields say Fahrenheit, and the unit system is what makes HA
report in it — finishes onboarding, and mints the long-lived access token
Dobby authenticates with. It prints the credentials and writes them nowhere.

Then restart HA once, so entities rendered before the unit change re-render
in °F:

```sh
docker compose restart
```

To mint another token later: sign in at `http://localhost:8123`, open your
profile → Security → long-lived access tokens. To start the instance over:
`docker compose down && rm -rf config && docker compose up -d`, then
initialize again.

**Never commit a token.** The gitignored `dev/home-assistant/config/`
directory holds HA's own auth store; leave it that way.

## Point Dobby at it

`config/homes/local.yaml` is the committed home file for this house. It binds
the real client (`Dobby.HomeAssistant.Client`) and takes its credential from
the environment. In dev the environment starts from a gitignored `.env`:

```sh
cp .env.example .env    # then fill in the token onboard.exs printed
mix phx.server
```

Anything exported in the shell still wins over `.env`, and `mix test` never
reads it — the replay tier's determinism is not changeable by a file nobody
passed to mix. Without `DOBBY_HOME_MANIFEST`, everything runs against FakeHA
— the rig and the real house are the same application either side of the one
boundary.

Credentials for HA *integrations* (Honeywell TCC and friends) do not belong
in `.env` or anywhere else in this repo: they are entered once in the HA UI
and live in HA's own gitignored storage.

## Verify it

```sh
DOBBY_HOME_MANIFEST=config/homes/local.yaml \
  DOBBY_HA_URL=http://localhost:8123 DOBBY_HA_TOKEN=... \
  mix dobby.ha.verify --round-trip
```

Prints every device's snapshot once HA's initial state sync lands, then
drives the thermostat through a real setpoint change and waits for HA's
confirming `state_changed`. This is the development-integration layer of
the test story; `mix test` never needs HA running.

## The Roomba

The one integration that needs a human at the robot. In the HA UI:
Settings → Devices & Services → Add integration → **iRobot Roomba** → enter
the robot's IP (`192.168.86.21`; confirm under the iRobot app or the
router). When the flow asks for the password, make sure the robot is **on
its dock**, then **press and hold its Home button until it plays a tone**
— HA fetches the credential itself in that window.

Note the `vacuum.*` entity id HA creates, fill it into the commented
`vacuum:roomba` entry in `config/homes/local.yaml`, uncomment, and restart.
`mix dobby.ha.verify` should then show the robot with its battery.

## Household access

`DOBBY_LAN=1` (see `.env.example`) binds the dev server to every interface
and advertises this machine as `http://dobby.local:4000/` for exactly as long
as the server runs. A bare hostname needs a port-80 reverse proxy or service
capability. Anyone on the Wi-Fi can then open the thread by name — which is
the point: the second household speaker is what the multi-speaker design
exists for.

## Entity IDs

The manifest binds Dobby devices to HA entity IDs. To see what this
instance actually has: Developer Tools → States in the HA UI, or

```sh
curl -s -H "Authorization: Bearer $DOBBY_HA_TOKEN" \
  http://localhost:8123/api/states | jq -r '.[].entity_id'
```

If an entity ID in the manifest is wrong, its device boots as `NOT KNOWN`
and stays that way — `mix dobby.ha.verify` names it.
