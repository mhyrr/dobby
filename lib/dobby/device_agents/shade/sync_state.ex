defmodule Dobby.DeviceAgents.Shade.SyncState do
  @moduledoc """
  Translates Home Assistant cover state into household shade state.

  ## A shade's echo arrives over several reports

  A shade moves for seconds, and many report on the way: opening at 40, then
  at 70, then open at 100. A shade with no in-flight state reports `open` all
  the way down, because `CoverEntity.state` is open until the integration says
  closed. Judging only the last report as the echo wrote "changed at the
  shade" under Dobby's own command once per report on the way (TK-070 case 1).

  So while an accepted command is in flight, a report that moves the shade
  toward the commanded end is that command travelling: the in-flight state
  for its direction, or `open` with the position moving that way, and never
  past the target. The flight ends at the first of three things: the arrival,
  a report that is not travel toward the target (a hand turning the shade
  back), or a deadline's worth of silence since the last report on the way.
  A shade that goes unavailable mid-travel is still in flight when it answers.

  The bound is the point. The arrival keeps its standing echo, unchanged, so
  a hand that later returns the shade to a commanded end still has its last
  report read as ours; that is case 5, open in TK-064. A travel allowance with
  no end would have widened it to the hand's whole movement. An earlier
  attempt at this file was reverted for exactly that kind of trade, a
  suppression fixed by a fabrication.
  """

  use Jido.Action,
    name: "shade_sync_state",
    description: "Applies a Home Assistant state change to a shade",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @set_position 4

  @impl true
  def run(params, context) do
    previous = context.state

    next = %{
      available: available?(params.state),
      shade_state: shade_state(params.state),
      position: position(params.attributes["current_position"]),
      supports_position: supports?(params.attributes["supported_features"], @set_position)
    }

    keys = [:available, :shade_state, :position, :supports_position]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {commanded?, command} = judge(previous, next)

        {:ok, Map.put(next, :last_command, command),
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?
           )
         ]}
    end
  end

  # Whether this report is the command's, and the command as it stands after
  # it: still in flight only while the shade is travelling toward its end.
  #
  # A shade that stops answering has not been turned back by anybody, so the
  # flight survives it; going quiet is not movement and writes no line either
  # way (`DeviceAgent.changes/3`). Each report on the way pushes the window
  # on, so a slow awning stays in flight for as long as it keeps travelling.
  defp judge(%{last_command: command} = previous, next) do
    cond do
      next.available != true -> {false, command}
      commanded?(previous, next) -> {true, landed(command)}
      travelling?(command, previous, next) -> {true, still_in_flight(command)}
      true -> {false, landed(command)}
    end
  end

  defp still_in_flight(command),
    do: %{command | in_flight_until: Dobby.DeviceAgents.Shade.in_flight_until()}

  # Set to nil rather than deleted: Jido deep-merges an action's result into
  # agent state, so a key dropped from the nested command would survive.
  defp landed(%{in_flight_until: _} = command), do: %{command | in_flight_until: nil}
  defp landed(command), do: command

  defp travelling?(%{result: :accepted, in_flight_until: until} = command, previous, next)
       when is_integer(until) do
    System.monotonic_time(:millisecond) <= until and
      case target(command, previous.position) do
        {direction, target} -> heading?(direction, target, previous.position, next)
        nil -> false
      end
  end

  defp travelling?(_command, _previous, _next), do: false

  defp target(%{action: :open}, _from), do: {:up, 100}
  defp target(%{action: :close}, _from), do: {:down, 0}

  defp target(%{action: :set_position, position: to}, from) when is_integer(from) do
    cond do
      to > from -> {:up, to}
      to < from -> {:down, to}
      true -> nil
    end
  end

  defp target(_command, _from), do: nil

  # Toward the target and not past it. A report that only changes the state
  # (closed at 0, then opening at 0) is the start of the travel, so the
  # in-flight state may keep the position; `open` may not, because an open
  # shade that did not move is not evidence of anything.
  defp heading?(direction, target, from, %{shade_state: state, position: to}) do
    in_flight = if direction == :up, do: :opening, else: :closing

    if is_integer(from) and is_integer(to) do
      toward? =
        if direction == :up, do: from < to and to <= target, else: target <= to and to < from

      (state == in_flight and (toward? or to == from)) or (state == :open and toward?)
    else
      state == in_flight
    end
  end

  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  defp snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :shade,
      available: next.available,
      shade_state: next.shade_state,
      position: next.position,
      supports_position: next.supports_position
    }
  end

  # `unknown` is answering. Home Assistant reports it for a cover that cannot
  # say where it is (an RF motor with assumed state), which is a cover whose
  # state Dobby does not know, not one that stopped answering. Collapsing it
  # into unavailable refused every command to a working shade.
  defp available?(state), do: state not in [nil, "unavailable"]
  defp shade_state("open"), do: :open
  defp shade_state("closed"), do: :closed
  defp shade_state("opening"), do: :opening
  defp shade_state("closing"), do: :closing
  defp shade_state("stopped"), do: :stopped
  defp shade_state(_state), do: nil
  defp position(value) when is_integer(value) and value in 0..100, do: value
  defp position(value) when is_float(value) and value >= 0 and value <= 100, do: round(value)
  defp position(_value), do: nil

  defp supports?(features, flag) when is_integer(features),
    do: Bitwise.band(features, flag) == flag

  defp supports?(_features, _flag), do: false

  defp commanded?(%{last_command: %{result: :accepted, action: :open}}, next),
    do: next.shade_state == :open

  defp commanded?(%{last_command: %{result: :accepted, action: :close}}, next),
    do: next.shade_state == :closed

  defp commanded?(%{last_command: %{result: :accepted, position: position}}, next),
    do: next.position == position

  defp commanded?(_previous, _next), do: false
end
