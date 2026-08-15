defmodule Dobby.DeviceAgents.Thermostat.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into thermostat agent state.

  This is the only way thermostat readings ever change. A command Dobby issues
  does not update this agent — the command goes to HA, HA moves the world, and
  the world comes back through here. That round trip is why the system prompt
  can tell the model to report what it commanded rather than claim it observed
  the result.

  Capability discovery (design §4.3) rides along: `min_temp`, `max_temp`, and
  the step arrive as ordinary attributes, and they are the device's real
  envelope.
  """

  use Jido.Action,
    name: "thermostat_sync_state",
    description: "Applies a Home Assistant state change to thermostat agent state",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: :map, default: %{}]
    ]

  alias Dobby.DeviceEvents

  # HA reports temperatures in the unit system the instance is configured for.
  # Dobby's field names say Fahrenheit and the rig speaks Fahrenheit; whether
  # the real house does is a Phase B inventory question, not something to
  # paper over with a guess at a conversion here.
  @impl true
  def run(params, context) do
    previous = context.state
    attributes = params.attributes

    next = %{
      available: params.state not in [nil, "unavailable", "unknown"],
      hvac_mode: parse_mode(params.state),
      current_temperature_f: attribute(attributes, [:current_temperature, "current_temperature"]),
      target_temperature_f: attribute(attributes, [:temperature, "temperature"]),
      capabilities: discover_capabilities(previous.capabilities, attributes)
    }

    if meaningful_change?(previous, next) do
      {:ok, next, [DeviceEvents.emit(previous.dobby_id, snapshot(previous, next))]}
    else
      {:ok, next}
    end
  end

  @doc """
  The device's public state, read from live agent state.

  `Dobby.DeviceAgent.snapshot/1` for this device type: a surface that has just
  opened needs the house as it is now, and state-change events only describe
  changes.
  """
  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  @doc """
  The device's public state — what cards render and the model is told.
  """
  @spec snapshot(map(), map()) :: map()
  def snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :thermostat,
      available: next.available,
      current_temperature_f: next.current_temperature_f,
      target_temperature_f: next.target_temperature_f,
      hvac_mode: next.hvac_mode
    }
  end

  # Capability discovery is additive: an event that omits the envelope
  # attributes must not erase what a previous event taught us.
  defp discover_capabilities(previous, attributes) do
    [
      {:min_temperature_f, [:min_temp, "min_temp"]},
      {:max_temperature_f, [:max_temp, "max_temp"]},
      {:step_f, [:target_temp_step, "target_temp_step"]},
      {:hvac_modes, [:hvac_modes, "hvac_modes"]}
    ]
    |> Enum.reduce(previous || %{}, fn {key, aliases}, acc ->
      case attribute(attributes, aliases) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp meaningful_change?(previous, next) do
    Enum.any?([:available, :hvac_mode, :current_temperature_f, :target_temperature_f], fn key ->
      Map.get(previous, key) != Map.get(next, key)
    end)
  end

  # HA's climate hvac_mode vocabulary is closed. Anything outside it is a
  # genuine surprise, and reads better as "we don't know" than as an atom
  # conjured from whatever the integration happened to send.
  @hvac_modes %{
    "off" => :off,
    "heat" => :heat,
    "cool" => :cool,
    "heat_cool" => :heat_cool,
    "auto" => :auto,
    "dry" => :dry,
    "fan_only" => :fan_only
  }

  defp parse_mode(state), do: Map.get(@hvac_modes, state)

  defp attribute(attributes, keys) do
    Enum.find_value(keys, fn key -> Map.get(attributes, key) end)
  end
end
