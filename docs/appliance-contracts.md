# Household appliance contracts

Decision, 2026-09-11: Greg wants the device library completed from Dobby's
perspective. Home Assistant owns brands, model compatibility, accounts, and
transport. A model number is not a prerequisite for a Dobby device contract.

## Scope

Add the remaining categories from the appliance survey: water heater,
humidifier, dehumidifier, air purifier, range hood, coffee maker, wine cooler,
ice maker, cooktop, and microwave. Standalone freezers reuse `refrigerator`;
floor heating reuses `thermostat`. The five existing kitchen/laundry types stay.
This is the household appliance scope, not every Home Assistant entity domain.

## Controls and observations

- Water heaters bind `water_heater.*`. Read temperature, target, unit, mode,
  away state and capabilities. Support target temperature, operation mode,
  away mode, and power only where HA advertises those capabilities. Validate
  discovered ranges and optional household bounds. Never assume Fahrenheit
  from a number. Commands carry units explicitly; the device computes conversion
  if its interface uses a fixed public unit.
- Humidifier and dehumidifier are separate semantic types over `humidifier.*`,
  distinguished by HA device class. Read current/target humidity, power,
  action, mode and capabilities. Support power, humidity target and advertised
  modes. Refuse unavailable devices, unknown capabilities, out-of-range targets,
  incompatible device classes and modes absent from HA's list.
- Air purifier and range hood use the HA fan interface for power and speed.
  Their semantic identities stay distinct. Additional filter
  readings are optional; use an environment monitor for air-quality sensors; a range hood's light remains a normal light entry.
- Coffee maker, wine cooler, ice maker, cooktop and microwave have no standard
  HA entity control domain. Add explicit read-only scalar bindings with distinct
  state vocabularies and meaningful status tools. Do not invent service names,
  arbitrary-service tools, or a generic power switch for these appliances.
  A future control binding must state its HA contract and command-arrival rule;
  it does not require brand logic in Dobby.

## Implementation and acceptance

Keep the existing device behaviour, closed tool library, manifest validation,
HA signal boundary, command acceptance/echo protocol, and schedule interface.
No model arithmetic, network access from tools, new credentials or dependencies.
Commands never mutate observed readings. Unit/capability changes must propagate
through snapshots, including loss of knowledge on unavailable reports.

Register every type and its literal tools, add same-named contract tests,
extend the example house and docs, and exercise HA-shaped inputs through live
agents. Tests cover refusal before HACall, capability/range/unit handling,
command arrival, first report versus movement, unknown values and wrong roster
types. Run `mix precommit`. No new visual design or physical-device claims.

Sources: [water heater entity](https://developers.home-assistant.io/docs/core/entity/water-heater/),
[humidifier entity](https://developers.home-assistant.io/docs/core/entity/humidifier/),
[fan interface](https://www.home-assistant.io/integrations/fan/).

## Binding reference

The [example house](../config/homes/example.yaml) includes every registered type.
Entity IDs are examples. Use IDs from the household's HA instance.

| Type | Required binding | Optional readings | Controls |
|---|---|---|---|
| `water_heater` | `water_heater` | Native temperature, target, mode, away state, ranges and feature flags | Temperature, advertised mode, away mode, power; each requires its feature flag |
| `humidifier`, `dehumidifier` | `humidifier` with matching HA device class | Native current/target humidity, power, action, mode, range and modes | Power, whole-percent target within range/step, advertised mode |
| `air_purifier`, `range_hood` | `fan` | `filter_remaining` (% sensor), `filter_due` (binary sensor) | Power and supported percentage speed |
| `coffee_maker` | At least one reading | `operation_state`, `program`, `water_empty`, `beans_empty`, `grounds_full`, `cleaning_required`, `remote_start_allowed` | Status only |
| `wine_cooler` | At least one reading | `temperature`, `target_temperature`, `upper_temperature`, `lower_temperature`, `upper_target_temperature`, `lower_target_temperature`, `door_open` | Status only |
| `ice_maker` | At least one reading | `operation_state`, `ice_full`, `water_empty`, `cleaning_required` | Status only |
| `cooktop` | At least one reading | `operation_state`, `active`, `hot_surface`, `power_level` (% sensor) | Status only; use one entry per reported heating zone |
| `microwave` | At least one reading | `operation_state`, `door_open`, `remaining_time`, `finish_at`, `remote_start_allowed` | Status only |

Water-heater tools take Fahrenheit values and convert to HA's unit in deterministic
code. HA normally omits the water-heater entity's unit; set
`settings.temperature_unit` to `°F`, `°C`, or `K` matching HA's system setting.
An explicit entity unit takes precedence. Missing or invalid units refuse
temperature control. Household min/max settings narrow HA's reported range.

Humidity targets use percent. Household min/max settings narrow HA's reported
range; reported target steps are respected. Mode strings must come from HA's
advertised list. The dehumidifier binds the `humidifier` domain because that is
HA's interface for both jobs.

Purifiers, hoods, and scalar appliance types require explicit manifest bindings;
entity names do not establish their household role. Scalar temperatures retain
their units and distinguish measured values from setpoints. Unknown readings
remain null. A working sensor does not establish that all other readings are
known, and a zero duration does not establish that a cycle finished.

All writable types declare schedulable actions through the existing device
interface. Filter sensors do not authorize fan commands. Hood lights are separate
light entries; environmental readings can use the existing environment monitor.

## Verification

Verified 2026-09-11 with `mix precommit`: 631 tests, 0 failures, 35 paid-model
evaluations excluded. The suite uses FakeHA with HA-shaped state objects and
real Dobby agents. It covers native service calls and echoes, unavailable
states, capability and range refusals, explicit units, sensor independence,
manifest round trips, tool registration, and command-value rendering.
Physical appliances have not been exercised. The rig house's cards were
looked at in the browser on 2026-09-14, when the card controls landed.
