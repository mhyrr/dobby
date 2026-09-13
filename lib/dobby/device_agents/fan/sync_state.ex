defmodule Dobby.DeviceAgents.Fan.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into fan agent state.

  The only way fan readings ever change, as with every type in the library: a
  command goes out, HA moves the world, and the world comes back through
  here. The `SET_SPEED` feature bit is decoded at this boundary so that
  everything above it sees `supports_speed`, a word — the number never
  travels further than the wire that carried it.
  """

  use Jido.Action,
    name: "fan_sync_state",
    description: "Applies a Home Assistant state change to a fan",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @set_speed 1

  @impl true
  def run(params, context) do
    previous = context.state

    next = decode(params)

    keys = [:available, :power, :speed_percent, :speed_step, :supports_speed]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        commanded = commanded(previous, next, changed)

        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded: commanded,
             commanded?: commanded != []
           )
         ]}
    end
  end

  @doc false
  def decode(params) do
    %{
      available: available?(params.state),
      power: power(params.state),
      speed_percent: percent(params.attributes["percentage"]),
      speed_step: step(params.attributes["percentage_step"]),
      supports_speed: supports?(params.attributes["supported_features"], @set_speed)
    }
  end

  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  defp snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :fan,
      available: next.available,
      power: next.power,
      speed_percent: next.speed_percent,
      speed_step: next.speed_step,
      supports_speed: next.supports_speed
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp power("on"), do: :on
  defp power("off"), do: :off
  defp power(_state), do: nil
  # How coarse this fan is. A three-speed fan advertises 33.3, and Home
  # Assistant snaps whatever percentage it is given to the nearest notch.
  defp step(value) when is_number(value) and value > 0 and value <= 100, do: value
  defp step(_value), do: nil

  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(value) when is_float(value) and value >= 0 and value <= 100, do: round(value)
  defp percent(_value), do: nil

  defp supports?(features, flag) when is_integer(features),
    do: Bitwise.band(features, flag) == flag

  defp supports?(_features, _flag), do: false

  # What this command accounts for in this report, so the watcher can judge
  # whatever is left on its own.
  #
  # Power and speed move together in Home Assistant's fan contract: a
  # percentage turns the fan on, a turn-on restores the speed it had, and a
  # turn-off drops the percentage to zero. Claiming only the attribute the
  # command was named for left the other one looking like a hand. The first
  # attribute gates the rest, so a later report that moves the speed alone is
  # still somebody's doing — which is the thing this was written to fix.
  defp commanded(previous, next, changed) do
    case command_attributes(previous.last_command) do
      [primary | _] = attributes ->
        if primary in changed and
             Dobby.DeviceAgents.Fan.command_arrived?(
               previous.last_command,
               snapshot(previous, next)
             ),
           do: Enum.filter(attributes, &(&1 in changed)),
           else: []

      [] ->
        []
    end
  end

  defp command_attributes(%{result: :accepted, action: :set_power}),
    do: [:power, :speed_percent]

  defp command_attributes(%{result: :accepted, action: :set_speed}),
    do: [:speed_percent, :power]

  defp command_attributes(_command), do: []
end
