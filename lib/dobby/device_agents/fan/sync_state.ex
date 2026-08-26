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

    next = %{
      available: available?(params.state),
      power: power(params.state),
      speed_percent: percent(params.attributes["percentage"]),
      supports_speed: supports?(params.attributes["supported_features"], @set_speed)
    }

    keys = [:available, :power, :speed_percent, :supports_speed]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?(previous, next)
           )
         ]}
    end
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
      supports_speed: next.supports_speed
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp power("on"), do: :on
  defp power("off"), do: :off
  defp power(_state), do: nil
  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(value) when is_float(value) and value >= 0 and value <= 100, do: round(value)
  defp percent(_value), do: nil

  defp supports?(features, flag) when is_integer(features),
    do: Bitwise.band(features, flag) == flag

  defp supports?(_features, _flag), do: false

  defp commanded?(%{last_command: %{result: :accepted, power: power}}, next),
    do: next.power == power

  defp commanded?(%{last_command: %{result: :accepted, speed_percent: percent}}, next),
    do: next.speed_percent == percent

  defp commanded?(_previous, _next), do: false
end
