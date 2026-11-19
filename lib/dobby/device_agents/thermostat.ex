defmodule Dobby.DeviceAgents.Thermostat do
  @moduledoc """
  A thermostat, as Dobby understands one (design §7.1).

  Deterministic and signal-driven. It owns interpretation of its HA entity,
  the setpoint range it will accept, and the translation of `set_temperature`
  into an HA service call. It does not own a credential, a connection, or an
  opinion about language.

  Its capability envelope is *discovered* from the bound entity rather than
  declared (design §4.3): `min_temp`, `max_temp`, and the step come from the
  hardware, and the manifest's `settings` only narrow that to household
  policy. A manifest therefore cannot authorize a setpoint the device rejects.
  """

  use Jido.Agent,
    name: "thermostat",
    description: "Reports thermostat state and changes its setpoint",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Thermostat.SyncState},
      {"thermostat.set_temperature", Dobby.DeviceAgents.Thermostat.SetTemperature}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      # `nil` and not `false`: "nobody has told us yet" and "the device is
      # not answering" are different facts, and the board has a different word
      # for each. Defaulting to `false` made a thermostat that had simply not
      # reported yet look like one that had gone quiet.
      available: [type: {:or, [:boolean, nil]}, default: nil],
      current_temperature_f: [type: {:or, [:integer, :float, nil]}, default: nil],
      target_temperature_f: [type: {:or, [:integer, :float, nil]}, default: nil],
      hvac_mode: [type: {:or, [:atom, nil]}, default: nil],
      capabilities: [type: :map, default: %{}],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  @impl Dobby.DeviceAgent
  def observables,
    do: %{
      current_temperature_f: :number,
      target_temperature_f: :number,
      hvac_mode: {:enum, [:off, :heat, :cool, :heat_cool, :auto, :dry, :fan_only]}
    }

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def config_type, do: "thermostat"

  @impl Dobby.DeviceAgent
  # This integration exposes oven and refrigeration controls as climate
  # entities. Offering them as room thermostats would authorize cooking via
  # the ordinary setpoint tool. HA's domain alone is not a semantic type.
  def matches_entity?(entity),
    do: Dobby.HomeAssistant.Entity.domain(entity) == "climate" and entity.platform != "subzero"

  # Household policy, and only that. The hardware's own envelope is discovered
  # from the bound entity, so these narrow what the device already allows and
  # can never widen it — a manifest cannot authorize a setpoint the furnace
  # rejects.
  @impl Dobby.DeviceAgent
  def config_schema do
    [
      min_temperature_f: [
        type: {:or, [:integer, :float]},
        doc: "The coolest this household will let anyone set the thermostat."
      ],
      max_temperature_f: [
        type: {:or, [:integer, :float]},
        doc: "The warmest this household will let anyone set the thermostat."
      ]
    ]
  end

  @impl Dobby.DeviceAgent
  def validate_device(%Device{bindings: bindings, settings: settings}) do
    with :ok <- require_binding(bindings, :climate) do
      validate_settings(settings)
    end
  end

  @impl Dobby.DeviceAgent
  def tools do
    [Dobby.Tools.ThermostatGetStatus, Dobby.Tools.ThermostatSetTemperature]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:climate]

  @impl Dobby.DeviceAgent
  def scheduled_actions do
    %{
      set_temperature:
        {"thermostat.set_temperature", Dobby.DeviceAgents.Thermostat.SetTemperature}
    }
  end

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Thermostat.SyncState

  # The setpoint, between the ends the snapshot already carries. Offered only
  # once the device has reported a setpoint and a range that is a range: a
  # thermostat that has said nothing has not told us what it will accept,
  # which is a different fact from one that said no.
  @impl Dobby.DeviceAgent
  def controls(%{
        available: true,
        target_temperature_f: target,
        min_temperature_f: min,
        max_temperature_f: max
      })
      when is_number(target) and is_number(min) and is_number(max) and min < max do
    [
      %{
        kind: :fader,
        action: :set_temperature,
        arg: :temperature_f,
        field: :target_temperature_f,
        min: min,
        max: max,
        step: 1,
        unit: "°"
      }
    ]
  end

  def controls(_snapshot), do: []

  # The setpoint is the only thing about a thermostat somebody can *do*. The
  # room's temperature changing is the house being a house, and a thread that
  # announced every degree would bury the sentences people came to read.
  @impl Dobby.DeviceAgent
  def intervention?(:target_temperature_f), do: true
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, temperature_f: _} = command, %{
        target_temperature_f: reported
      }),
      do: echoes?(command, reported)

  def command_arrived?(_command, _snapshot), do: false

  @doc """
  Whether a reported setpoint is what Home Assistant sends back for this command.

  Not the number Dobby sent. `ClimateEntity` reports its target through
  `show_temp` at the entity's precision, which is whole degrees on a Fahrenheit
  house, and integrations snap a target to the device's step before sending it.
  "Seventy and a half" therefore comes back as 70 (or 71), and comparing at
  float equality called that a command that never arrived and a hand on the
  dial at once: a NOT KNOWN line and a "changed at the thermostat" line, both
  for Dobby's own command.

  Half a reporting step is the most rounding can move a value, so that is the
  tolerance, inclusive because 70.5 is exactly half a degree from both
  neighbours and Python rounds half to even. The step is the one the device
  reported when the command was accepted (`target_temp_step`), and never less
  than a whole degree, because precision, which HA does not publish, is whole
  degrees on a Fahrenheit house however fine the step. A hand still reads as a
  hand: it moves the dial by at least one step, which is twice the tolerance.

  The cost, stated: a command between two steps accepts either neighbour as
  its echo, so a hand that moves 70.5 to 71 straight after is read as ours.
  """
  @spec echoes?(map(), number() | nil) :: boolean()
  def echoes?(%{temperature_f: expected} = command, reported)
      when is_number(expected) and is_number(reported),
      do: abs(expected - reported) <= max(command[:step_f] || 1, 1) / 2

  def echoes?(_command, _reported), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device),
    do: Dobby.DeviceAgent.initial_state(device, :climate)

  @doc """
  The setpoint range this thermostat will accept right now.

  The intersection of what the hardware reported and what the household
  configured. `nil` on either side simply means that side is unbounded, so a
  thermostat with no profile and no settings still works — it is just governed
  by HA alone.
  """
  @spec accepted_range(map()) :: {number() | nil, number() | nil}
  def accepted_range(state) do
    capabilities = Map.get(state, :capabilities) || %{}
    settings = Map.get(state, :settings) || %{}

    {
      narrowest(&max/2, capabilities[:min_temperature_f], settings[:min_temperature_f]),
      narrowest(&min/2, capabilities[:max_temperature_f], settings[:max_temperature_f])
    }
  end

  defp narrowest(_fun, nil, other), do: other
  defp narrowest(_fun, value, nil), do: value
  defp narrowest(fun, a, b), do: fun.(a, b)

  defp require_binding(bindings, key) when is_map(bindings) do
    case Map.fetch(bindings, key) do
      {:ok, entity_id} when is_binary(entity_id) ->
        :ok

      {:ok, other} ->
        {:error, "bindings.#{key} must be an entity id string, got #{inspect(other)}"}

      :error ->
        {:error, "missing required binding #{inspect(key)}"}
    end
  end

  defp require_binding(other, _key),
    do: {:error, "bindings must be a map, got #{inspect(other)}"}

  defp validate_settings(settings) when is_map(settings) do
    min = Map.get(settings, :min_temperature_f)
    max = Map.get(settings, :max_temperature_f)

    cond do
      min != nil and not is_number(min) ->
        {:error, "settings.min_temperature_f must be a number, got #{inspect(min)}"}

      max != nil and not is_number(max) ->
        {:error, "settings.max_temperature_f must be a number, got #{inspect(max)}"}

      is_number(min) and is_number(max) and min > max ->
        {:error, "settings.min_temperature_f (#{min}) exceeds max_temperature_f (#{max})"}

      true ->
        :ok
    end
  end

  defp validate_settings(other), do: {:error, "settings must be a map, got #{inspect(other)}"}
end
