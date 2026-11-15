defmodule Dobby.DeviceAgents.Vacuum.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into vacuum agent state.

  The only way vacuum readings ever change: a command goes out, the robot
  moves, and the movement comes back through here — including the movements
  nobody commanded, like the robot deciding its bin is full.
  """

  use Jido.Action,
    name: "vacuum_sync_state",
    description: "Applies a Home Assistant state change to vacuum agent state",
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

    next = update(previous.bindings, params)

    case DeviceAgent.changes(previous, next, Map.keys(next)) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(Map.merge(previous, next)),
             changed: changed,
             moved: moved
           )
         ]}
    end
  end

  @doc """
  The device's public state, read from live agent state.
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
      type: :vacuum,
      available: next.available,
      activity: next.activity,
      battery_percent: next.battery_percent
    }
  end

  # A battery sensor, when the house binds one, owns the reading: the vacuum's
  # own reports leave it alone, because on HA 2026.8 and later they no longer
  # carry `battery_level` and reading the absent attribute would erase what
  # the sensor said. Without the binding the attribute is still read, for an
  # older HA.
  defp update(%{battery: entity_id}, %{entity_id: entity_id, state: state}),
    do: %{battery_percent: battery(state)}

  defp update(bindings, %{entity_id: entity_id} = params) do
    if bindings[:vacuum] == entity_id do
      vacuum = %{
        available: params.state not in [nil, "unavailable", "unknown"],
        activity: parse_activity(params.state)
      }

      if Map.has_key?(bindings, :battery),
        do: vacuum,
        else: Map.put(vacuum, :battery_percent, battery(params.attributes["battery_level"]))
    else
      %{}
    end
  end

  defp battery(level) when is_number(level), do: round(level)

  defp battery(level) when is_binary(level) do
    case Float.parse(level) do
      {value, ""} when value >= 0 and value <= 100 -> round(value)
      _not_a_reading -> nil
    end
  end

  defp battery(_absent), do: nil

  # HA's vacuum activity vocabulary is closed. Anything outside it is a
  # genuine surprise, and reads better as "we don't know".
  @activities %{
    "cleaning" => :cleaning,
    "docked" => :docked,
    "paused" => :paused,
    "idle" => :idle,
    "returning" => :returning,
    "error" => :error
  }

  defp parse_activity(state), do: Map.get(@activities, state)
end
