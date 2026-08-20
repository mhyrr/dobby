defmodule Dobby.DeviceAgents.Light.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into light agent state.

  The only way light readings ever change, exactly as with the thermostat: a
  command goes out, HA moves the world, and the world comes back through
  here. Brightness arrives as HA's 0–255 and is kept as a percentage,
  because "the kitchen light is at 180" is nobody's sentence.
  """

  use Jido.Action,
    name: "light_sync_state",
    description: "Applies a Home Assistant state change to light agent state",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      # String keys — see Thermostat.SyncState: bare `:map` means atom keys,
      # which real HA's JSON attributes are not.
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @impl true
  def run(params, context) do
    previous = context.state
    attributes = params.attributes

    next = %{
      available: params.state not in [nil, "unavailable", "unknown"],
      power: parse_power(params.state),
      brightness_percent: brightness_percent(attributes["brightness"]),
      capabilities: discover_capabilities(previous.capabilities, attributes)
    }

    case DeviceAgent.changes(previous, next, [:available, :power, :brightness_percent]) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved
           )
         ]}
    end
  end

  @doc """
  The device's public state, read from live agent state.

  `Dobby.DeviceAgent.snapshot/1` for this device type: a surface that has
  just opened needs the house as it is now, and state-change events only
  describe changes.
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
      type: :light,
      available: next.available,
      power: next.power,
      brightness_percent: next.brightness_percent
    }
  end

  # An off light reports brightness null, and a switch-only light never
  # reports it. Both read as "no brightness to speak of", which is nil.
  defp brightness_percent(brightness) when is_number(brightness),
    do: round(brightness / 255 * 100)

  defp brightness_percent(_absent), do: nil

  # Capability discovery is additive: an event that omits the envelope must
  # not erase what a previous event taught us. `supported_color_modes` is
  # HA's word for what this bulb can be asked — everything else about color
  # is deliberately ignored for now.
  defp discover_capabilities(previous, attributes) do
    case attributes["supported_color_modes"] do
      modes when is_list(modes) -> Map.put(previous || %{}, :color_modes, modes)
      _absent -> previous || %{}
    end
  end

  # "on" and "off" are the vocabulary; anything else is a genuine surprise
  # and reads better as "we don't know".
  defp parse_power("on"), do: :on
  defp parse_power("off"), do: :off
  defp parse_power(_other), do: nil
end
