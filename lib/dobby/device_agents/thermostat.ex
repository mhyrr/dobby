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

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def config_type, do: "thermostat"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Dobby.HomeAssistant.Entity.domain(entity) == "climate"

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

  # The setpoint is the only thing about a thermostat somebody can *do*. The
  # room's temperature changing is the house being a house, and a thread that
  # announced every degree would bury the sentences people came to read.
  @impl Dobby.DeviceAgent
  def intervention?(:target_temperature_f), do: true
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device) do
    %{
      dobby_id: device.id,
      name: device.name,
      entity_id: Map.fetch!(device.bindings, :climate),
      settings: device.settings
    }
  end

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
