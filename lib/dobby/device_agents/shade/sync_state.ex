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

  The bound is the point. A travel allowance with no end would read a hand's
  whole movement as ours. An earlier attempt at this file was reverted for
  exactly that kind of trade, a suppression fixed by a fabrication.

  ## The echo is spent at the arrival

  One-shot, as the lock's is (Greg, 2026-11-16, TK-064). Open and closed are
  two values, so a standing echo read every hand that put the shade back
  where Dobby had once sent it as Dobby's. The arrival is the state for open
  and close, or a position within one notch of the target, and it may claim
  one more report: a settle of one notch in the same state toward its end.
  Every report after that is anybody's.
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
  #
  # After the arrival the command has one report left to claim: a settle of
  # one notch in the same state, toward its end (open at 99, then 100). Any
  # report after that, or any other report, spends it. Spent is `nil`, not a
  # key removed: Jido deep-merges an action's result into agent state, so a
  # key dropped from the nested command would survive.
  defp judge(%{last_command: command} = previous, next) do
    cond do
      next.available != true -> {false, command}
      match?(%{arrived: true}, command) -> {settling?(command, previous, next), nil}
      in_flight?(command) and commanded?(previous, next) -> {true, arrived(command)}
      travelling?(command, previous, next) -> {true, still_in_flight(command)}
      true -> {false, nil}
    end
  end

  defp still_in_flight(command),
    do: %{command | in_flight_until: Dobby.DeviceAgents.Shade.in_flight_until()}

  defp arrived(command),
    do:
      Map.merge(command, %{
        arrived: true,
        in_flight_until: Dobby.DeviceAgents.Shade.in_flight_until()
      })

  # The arrival is bounded by the deadline too. A command whose shade never
  # moved would otherwise wait for ever, and the next hand to close the shade,
  # an hour later, would arrive as its echo.
  defp in_flight?(%{in_flight_until: until}) when is_integer(until),
    do: System.monotonic_time(:millisecond) <= until

  defp in_flight?(_command), do: false

  # One notch, in the same state, and closer to the end than the arrival was.
  # A notch away from the end is somebody nudging it. One clause answers for
  # every command: no deadline, no position, or no end each makes it false.
  defp settling?(command, previous, next) do
    from = previous.position
    to = next.position
    target = end_position(command)

    in_flight?(command) and next.shade_state == previous.shade_state and
      is_integer(from) and is_integer(to) and is_integer(target) and abs(to - from) <= 1 and
      abs(to - target) < abs(from - target)
  end

  defp end_position(%{action: :open}), do: 100
  defp end_position(%{action: :close}), do: 0
  defp end_position(%{position: position}), do: position
  defp end_position(_command), do: nil

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

  # `open` is every position above closed, so with a position it arrives only
  # within a notch of fully open; below that it is the open still travelling.
  # A shade with no position has only the word to go on.
  defp commanded?(%{last_command: %{result: :accepted, action: :open}}, next),
    do: next.shade_state == :open and (is_nil(next.position) or next.position >= 99)

  defp commanded?(%{last_command: %{result: :accepted, action: :close}}, next),
    do: next.shade_state == :closed

  # One notch either side, the shape of the thermostat's and the dimmer's
  # tolerance: a motor lands where its encoder lands, and 51 for 50 is the
  # command arriving, not a hand.
  defp commanded?(%{last_command: %{result: :accepted, position: position}}, next)
       when is_integer(position) and is_integer(next.position),
       do: abs(next.position - position) <= 1

  defp commanded?(_previous, _next), do: false
end
