defmodule Dobby.Conversation.Turn.QueueTest do
  @moduledoc """
  One person has the floor at a time (`TK-006`).

  ## Why the runner is injected here and nowhere else

  A scripted turn finishes in microseconds, so racing two of them proves
  nothing: whichever order they happen to land in, the assertion passes. The
  only way to observe *ordering* is to hold the first turn open and look at what
  the second one did while it waited — which needs a runner that blocks until
  this test lets go.

  That is a seam rather than a fake. The queue's job is ordering and the thing
  it orders is a black box to it; the production runner is `Turn.answer/4`, and
  `Dobby.Conversation.TurnTest` proves the real one answers through the same
  door.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Conversation.Turn.Queue
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  setup do
    ThreadEvents.subscribe()

    {:ok, greg} = Conversation.name_speaker("greg")
    {:ok, sam} = Conversation.name_speaker("sam")

    test = self()

    # Announces itself and then holds the floor until this test lets go — or
    # dies on command, which is the only way to watch the floor being freed by
    # something going wrong rather than by something finishing.
    runner = fn utterance, _speaker, _request_id, _opts ->
      send(test, {:started, utterance.text, self()})

      receive do
        :release -> :ok
        :crash -> raise "this turn died holding the floor"
      after
        2_000 -> raise "a held turn was never released"
      end
    end

    queue = start_supervised!({Queue, name: __MODULE__, runner: runner})

    %{queue: queue, greg: greg, sam: sam}
  end

  test "a second utterance waits rather than being thrown away", ctx do
    say(ctx, ctx.greg, "put the heat on")
    assert_receive {:started, "put the heat on", first}, 2_000

    say(ctx, ctx.sam, "and is the printer awake?")

    # The whole of TK-006 in two assertions. Before the queue, this utterance
    # was rejected outright with `reason: :busy` and never reached the model.
    # It is in the thread, and it is next.
    assert_receive {:said, %Message{text: "and is the printer awake?"}}, 2_000
    refute_receive {:started, "and is the printer awake?", _pid}, 200

    send(first, :release)
    assert_receive {:started, "and is the printer awake?", second}, 2_000
    send(second, :release)
  end

  # Their words, immediately. A person whose message sat invisible until the
  # agent freed up would reasonably conclude the house had stopped listening.
  test "the waiting speaker sees what they said straight away", ctx do
    say(ctx, ctx.greg, "put the heat on")
    assert_receive {:started, _text, first}, 2_000

    say(ctx, ctx.sam, "and the printer?")
    assert_receive {:said, %Message{text: "and the printer?", speaker: %{name: "sam"}}}, 2_000

    assert Enum.map(Conversation.list_messages(), & &1.text) ==
             ["put the heat on", "and the printer?"]

    send(first, :release)

    # And it does get answered, once the floor is free.
    assert_receive {:started, "and the printer?", second}, 2_000
    send(second, :release)
  end

  test "they take the floor in the order they were said", ctx do
    say(ctx, ctx.greg, "one")
    assert_receive {:started, "one", first}, 2_000

    say(ctx, ctx.sam, "two")
    say(ctx, ctx.greg, "three")
    Queue.recorded(ctx.queue)

    assert Queue.waiting(ctx.queue) == 2

    send(first, :release)
    assert_receive {:started, "two", second}, 2_000
    refute_receive {:started, "three", _pid}, 200

    send(second, :release)
    assert_receive {:started, "three", third}, 2_000
    send(third, :release)
  end

  # The next utterance in a house is not conditional on the last one having
  # gone well.
  test "a turn that dies still frees the floor", ctx do
    say(ctx, ctx.greg, "the one that dies")
    assert_receive {:started, "the one that dies", first}, 2_000

    say(ctx, ctx.sam, "the one after it")
    refute_receive {:started, "the one after it", _pid}, 200

    send(first, :crash)

    assert_receive {:started, "the one after it", second}, 2_000
    send(second, :release)
  end

  # -- helpers ---------------------------------------------------------------

  defp say(%{queue: queue}, speaker, text) do
    GenServer.cast(queue, {:say, Utterance.new(speaker.name, text), speaker, []})
  end
end
