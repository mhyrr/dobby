defmodule Dobby.Conversation.TurnFoldTest do
  @moduledoc """
  What the fold does when the two tool events arrive in the wrong order.

  `Dobby.Conversation.TurnOrderingReproTest` measures how often that happens
  and needs hundreds of runs and a loaded machine to say anything. This says
  what happens when it does, in one run, every run: it hands
  `Dobby.Conversation.Turn.fold/3` the completion before the start, which is an
  order the runtime produces and no caller can ask for.

  The events are built here rather than captured, and the shapes are the ones
  measured off a real scripted turn: `seq` 5 and 6, one `tool_call_id`, string
  keys on the arguments because that is what they are on the wire. What is
  *not* faked is anything downstream — this is the production fold, the
  production `Dobby.Activity` write, and the real `Dobby.ThreadEvents`
  broadcast, so a step word going backwards would be visible here exactly as a
  surface would see it.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Activity
  alias Dobby.Conversation
  alias Dobby.Conversation.Turn
  alias Dobby.ThreadEvents
  alias Jido.AI.Runtime.Event

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @tool "thermostat_set_temperature"
  @arguments %{"device" => @thermostat, "temperature_f" => 71}

  setup do
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
    ThreadEvents.subscribe()

    {:ok, speaker} = Conversation.name_speaker("greg")

    Trace.reset()
    %{speaker: speaker, request_id: Jido.Util.generate_id()}
  end

  test "in order, the row knows its device and the step ends done", context do
    Turn.fold(events(:in_order, context), context.request_id, context.speaker)

    assert_receive {:step, _request_id, %{label: "setting the main thermostat", state: :running}}
    assert_receive {:step, _request_id, %{label: "setting the main thermostat", state: :done}}

    assert [entry] = tool_calls()
    assert entry.device == @thermostat
    assert entry.args["temperature_f"] == 71
    assert entry.result["state"] == "done"
  end

  test "swapped, the row still knows its device", context do
    Turn.fold(events(:swapped, context), context.request_id, context.speaker)

    # The arguments arrived after the result and the row was written anyway,
    # because it is written at the end of the turn rather than as the result
    # lands. A row with no device is a row that answers no question.
    assert [entry] = tool_calls()
    assert entry.device == @thermostat
    assert entry.args["temperature_f"] == 71
    assert entry.result["state"] == "done"
  end

  test "swapped, the state word never goes backwards", context do
    Turn.fold(events(:swapped, context), context.request_id, context.speaker)

    # The completion is folded first, so the board learns the step already done
    # — under the name the result alone can give it.
    assert_receive {:step, _request_id, %{state: :done} = first}
    refute first.label == "setting the main thermostat"

    # Then the start arrives, carrying the only copy of the name the arguments
    # make. It may improve the label. It may not take the word back to running.
    assert_receive {:step, _request_id, %{label: "setting the main thermostat", state: :done}}
    refute_receive {:step, _request_id, %{state: :running}}, 200
  end

  test "swapped, the reply records the step as finished", context do
    Turn.fold(events(:swapped, context), context.request_id, context.speaker)

    assert %{meta: meta} = Conversation.list_messages() |> List.last()

    # Built from the same map the board reads, so an unguarded fold would leave
    # a finished step reading as running here for as long as the thread is kept.
    assert [%{"label" => "setting the main thermostat", "state" => "done"}] = meta["steps"]
  end

  defp events(:in_order, context), do: [started(context), completed(context), done(context)]
  defp events(:swapped, context), do: [completed(context), started(context), done(context)]

  # seq 5 and 6 are the values measured on a real scripted actuating turn.
  defp started(%{request_id: request_id}) do
    event(request_id, 5, :tool_started, %{
      tool_call_id: "tc_1",
      tool_name: @tool,
      arguments: @arguments
    })
  end

  defp completed(%{request_id: request_id}) do
    event(request_id, 6, :tool_completed, %{
      tool_call_id: "tc_1",
      tool_name: @tool,
      duration_ms: 3,
      result:
        {:ok, %{accepted: true, device: @thermostat, name: "main thermostat", target_f: 71}, []}
    })
  end

  defp done(%{request_id: request_id}) do
    event(request_id, 7, :request_completed, %{result: "Set to 71.", usage: %{}})
  end

  defp event(request_id, seq, kind, data) do
    Event.new(%{
      seq: seq,
      run_id: request_id,
      request_id: request_id,
      iteration: 0,
      kind: kind,
      data: data
    })
  end

  defp tool_calls, do: Activity.recent() |> Enum.filter(&(&1.kind == "tool_call"))
end
