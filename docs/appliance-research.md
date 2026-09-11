# Household appliances and floor heat

Research and implementation decision, 2026-09-10; Bosch model confirmed
2026-09-11. Greg's dishwasher is SHV78DM3N/46. Wolf, Sub-Zero, and NuHeat model
numbers and the Home Assistant entity inventory are still pending.

## Type decisions

Add `dishwasher`, `oven`, `refrigerator`, `washer`, and `dryer` as household types. Keep floor heat
under `thermostat`. A combined range contains an oven and a cooktop; oven support
does not establish burner support. Refrigerator and freezer compartments belong
to one refrigerator, with separate readings and setpoints.

The first implementation reads explicitly bound HA sensor entities. It exposes
status tools, snapshots, and availability through the existing device protocol.
It does not start programs, set cooking temperatures, or change refrigeration
settings. Each reading retains its unit. A reported setpoint is never substituted
for an unreported temperature. Missing or unavailable readings become null.

Laundry extension, 2026-09-11: Greg requested washer and dryer in this branch.
Each is a separate read-only type with cycle/program state, door state,
progress, remaining time, finish timestamp, and remote-readiness flags. Remaining
time is a nonnegative numeric sensor with its reported seconds, minutes, or hours
unit; no model arithmetic or guessed completion time. Use the shared scalar
decoder and explicit bindings, with no new write commands. A stacked pair is
two devices. An all-in-one washer/dryer needs an actual entity inventory before
deciding how its shared cycle should be represented.

Discovery is deliberately manual: HA's sensor domain does not identify an
appliance type. Names are editable, and a temperature sensor is not evidence of
an oven. Add the bindings to the house YAML after inspecting the actual HA
entities. The discovery contract must test this refusal, not force a guessed
match. Known `subzero` climate entities are excluded from room-thermostat
discovery because that integration uses climate for oven and refrigerator controls.

Appliance observations are not interventions. This change adds no state words,
cards, model calls, network clients, credentials, or dependencies. The existing
board shows availability; detailed readings are available through the status
tools. Real appliance behavior and browser presentation remain unverified.

## Integration findings

- **Bosch 800 dishwasher, SHV78DM3N/46:** Greg confirmed this E-Nr on
  2026-09-11. Bosch's [exact-model support page](https://www.bosch-home.com/us/en/productservice/SHV78DM3N-46)
  identifies it as the 24-inch custom-panel-ready 800 Series. The
  [SHV78DM3N product page](https://www.bosch-home.com/us/en/product/dishwashers/top-controls/SHV78DM3N)
  confirms Wi-Fi-enabled Home Connect. Use Home Assistant's built-in
  [Home Connect integration](https://www.home-assistant.io/integrations/home_connect/).
  It uses Bosch's cloud API and requires a developer application and account
  authorization in HA. Available entities depend on the appliance and API access.
  The integration can expose program state, progress, finish time, door state,
  remote-start permission, program selection/start, and stop. The model's
  connectivity is confirmed; the entities and programs exposed to Greg's HA
  account still need inspection. Pair the dishwasher in Home Connect first.
- **NuHeat floor thermostat:** the built-in
  [NuHeat integration](https://www.home-assistant.io/integrations/nuheat/)
  supports Signature Wi-Fi thermostats through cloud polling. It needs the
  MyNuHeat account and numeric thermostat ID. HA exposes a climate entity.
  Dobby already reads it and sets its target through `climate.set_temperature`.
  NuHeat has no off mode. Schedule/hold selection exists in HA but is not yet
  a Dobby action. Do not describe a low setpoint as switching the system off.
- **Wolf and Sub-Zero:** community cloud and local Bluetooth integrations exist;
  see the model and capability notes below before choosing one. The brand names
  alone do not establish that these specific appliances can connect.

### Wolf and Sub-Zero options

The [cloud custom integration](https://github.com/orienw/ha-subzero) requires
Home Assistant 2026.8 or later and an appliance connected to the owner's account.
It uses undocumented endpoints. Its tested refrigerator is CL4850UFDID; Wolf
SO3050PMSP telemetry is tested, but oven commands have only simulated coverage.
It exposes separate sensor entities for oven temperature, setpoint, and probe;
fridge/freezer targets and reported display temperatures are also separate.
The temperature entities are conditional on reported properties and Fahrenheit
appliance configuration. HA can convert their display units. See the
[sensor implementation](https://github.com/orienw/ha-subzero/blob/main/custom_components/subzero/sensor.py).

The [ESPHome Bluetooth integration](https://github.com/JonGilmore/esphome-subzero-ble)
uses a local ESP32 and labels itself extreme alpha. It lists IR36550ST among
tested appliances. Oven temperature writes adjust an already-running cycle;
they do not start cooking. Refrigerator temperature readings are setpoints.
This is a possible local alternative after confirming the model and accepting
the additional hardware and maintenance.

[Wolf's connected-ready list](https://www.subzero-wolf.com/assistance/answers/multi-brand/connected-ready-appliances)
distinguishes current IR36550 from legacy IR365, which cannot be upgraded. It
also describes connected Sub-Zero families and serial-number-dependent models.
The newer [IR36551/S/P](https://ca.subzero-wolf.com/en/wolf/ranges/induction-range/36-inch-professional-induction-range)
has Wi-Fi app features, but that is not proof of integration testing.
[Remote Ready](https://www.subzero-wolf.com/assistance/answers/wolf/induction-range/induction-range-remote-ready-setup-with-app)
must be enabled at the appliance before remote oven starts. No cooktop-zone
control was found in either inspected integration.

### Other appliance families worth covering

| Integration | Appliance landscape | Dobby consequence |
|---|---|---|
| [LG ThinQ](https://www.home-assistant.io/integrations/lg_thinq/) | Built-in; washers, dryers, dishwashers, ovens, refrigerators, cooktops, hoods, microwaves, air and water appliances | Washer and dryer now have read-only types; verify each entity surface before adding control |
| [SmartThings](https://www.home-assistant.io/integrations/smartthings/) | Built-in; exposes supported Samsung capabilities, including oven and laundry status | Map capability data into household types; account visibility does not guarantee every appliance function |
| [Miele](https://www.home-assistant.io/integrations/miele/) | Built-in cloud integration for appliances linked to a Miele account; functions vary by device | Reuse dishwasher/oven/refrigerator/washer/dryer semantics where matching entities exist |
| [GE Appliances SmartHQ](https://github.com/geappliances/geappliances-smarthq-integration) | Manufacturer-hosted custom integration, installed separately; maps cloud services into cooking, laundry, temperature, door, and brewing entities | A concrete additional integration path; use exposed services to define capabilities |
| [Whirlpool Appliances](https://www.home-assistant.io/integrations/whirlpool/) | Built-in; Whirlpool, Maytag, KitchenAid, Consul, with model-dependent laundry, oven, and refrigeration functions | Keep target writes separate from passive readings: its oven target write can start a bake cycle |

`washer` and `dryer` are included in this branch. A separate freezer can reuse the
refrigerator compartment model. A range hood can use existing fan/light types
when those are the HA entities it provides. Cooktop, coffee maker, and water
heater need their own action contracts; they are not generic power switches.
The remaining candidates are research priorities, not support claims or additions in this branch.

## Binding the new types

Add entries under `house.devices` in the existing YAML, using the actual entity
IDs from HA. These are examples, not the discovered names of Greg's appliances:

```yaml
- id: dishwasher:kitchen
  type: dishwasher
  name: kitchen dishwasher
  bindings:
    operation_state: sensor.example_dishwasher_operation_state
    door_open: sensor.example_dishwasher_door
    progress: sensor.example_dishwasher_program_progress
    remote_start_allowed: binary_sensor.example_dishwasher_remote_start
- id: oven:kitchen
  type: oven
  name: kitchen oven
  bindings:
    temperature: sensor.example_oven_temperature
    target_temperature: sensor.example_oven_setpoint
    door_open: binary_sensor.example_oven_door
- id: refrigerator:kitchen
  type: refrigerator
  name: kitchen refrigerator
  bindings:
    refrigerator_target_temperature: sensor.example_refrigerator_setpoint
    freezer_target_temperature: sensor.example_freezer_setpoint
    refrigerator_door_open: binary_sensor.example_refrigerator_door
- id: thermostat:floor
  type: thermostat
  name: room floor heat
  bindings:
    climate: climate.example_nuheat
- id: washer:laundry
  type: washer
  name: laundry washer
  bindings:
    operation_state: sensor.example_washer_operation_state
    remaining_time: sensor.example_washer_remaining_time
    door_open: binary_sensor.example_washer_door
- id: dryer:laundry
  type: dryer
  name: laundry dryer
  bindings:
    operation_state: sensor.example_dryer_operation_state
    remaining_time: sensor.example_dryer_remaining_time
    remote_start_allowed: binary_sensor.example_dryer_remote_start
```

Omit entities the integration does not expose. Every appliance requires at least
one binding. For a second oven cavity, add a second oven entry. The new types
are configured through the house file; `discover_entities` and the proposal
flow do not offer them yet. Restart Dobby after editing the file.

| Type | Accepted binding keys |
|---|---|
| `dishwasher` | `operation_state`, `program`, `door_open`, `progress`, `finish_at`, `remote_start_allowed`, `remote_control_allowed` |
| `oven` | `temperature`, `target_temperature`, `probe_temperature`, `probe_target_temperature`, `door_open`, `running`, `at_temperature`, `remote_start_allowed`, `operation_state` |
| `refrigerator` | `refrigerator_display_temperature`, `refrigerator_target_temperature`, `freezer_display_temperature`, `freezer_target_temperature`, `crisper_target_temperature`, `refrigerator_door_open`, `freezer_door_open` |
| `washer` | `operation_state`, `program`, `door_open`, `progress`, `remaining_time`, `finish_at`, `remote_start_allowed`, `remote_control_allowed` |
| `dryer` | `operation_state`, `program`, `door_open`, `progress`, `remaining_time`, `finish_at`, `remote_start_allowed`, `remote_control_allowed` |

Temperature bindings read `sensor` or `number` with a reported °F, °C, or K unit.
Program/state text accepts `sensor` or `select`. Doors accept `binary_sensor`
on/off or `sensor` open/closed/locked. Other flags require `binary_sensor`.
Progress requires a sensor reporting 0–100 with unit `%`; `finish_at` requires
a sensor with an ISO 8601 timestamp. Laundry `remaining_time` requires a numeric
sensor reporting a nonnegative value with unit `s`, `min`, or `h`. A formatted
clock string such as `01:30` is not a numeric duration. No remaining time or
finish timestamp is computed by the model, and zero remaining time does not
mean the cycle has finished. Only the reported cycle state can say that.
Availability means at least one reading is known, not that every bound entity
is healthy. Each missing reading is null, including on partial outages.

The existing thermostat type assumes HA reports Fahrenheit. Check the HA unit
system before binding NuHeat; unit conversion for existing thermostats is a
separate unresolved limitation. Do not copy space-heating policy limits onto a
floor thermostat without checking its intended range.

## Validation plan

Exercise each registered type's shared contract and typed readings. Verify
partial outages, unknown/malformed values, retained units, unrelated signals,
and first-report versus movement behavior. Verify the real HA boundary with
FakeHA, live agents, and status tools. Cover NuHeat-shaped climate attributes
and appliance exclusion from thermostat discovery. Run `mix precommit`.

Verified 2026-09-11: the 26 focused appliance/contract tests passed, followed by
`mix precommit`: 566 tests, zero failures, 35 eval tests excluded. The example
house included the initial three types. After adding washer and dryer,
`mix precommit` passed with 574 tests, zero failures, and 35 eval tests excluded.
The example house and YAML round-trip test now cover all five appliance types.
The full run also exposed an existing library-test race: its state-event wait
did not identify the commanded device. The test now matches that device's
snapshot before reading its state. No physical appliance or browser check was
performed.

The workspace's existing dependency checkout did not match `mix.lock`, and its
ownership prevented updating it. Verification used the unchanged lockfile with
temporary caches:

```sh
HEX_HOME=/private/tmp/dobby-appliances-hex \
MIX_DEPS_PATH=/private/tmp/dobby-appliances-deps \
MIX_BUILD_PATH=/private/tmp/dobby-appliances-build mix precommit
```

## Next evidence

The Bosch E-Nr is recorded: SHV78DM3N/46. Obtain the Wolf, Sub-Zero, and NuHeat
models. Pair
supported devices in their manufacturer apps, then add the chosen integrations
in HA. Inspect entity IDs, units, available commands, program options, and remote
readiness. Do not copy account credentials into Dobby. Remote controls need
device-level validation, refusal behavior, and command-arrival evidence before
they can enter the language tool set.
