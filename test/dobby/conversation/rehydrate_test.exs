defmodule Dobby.Conversation.RehydrateTest do
  @moduledoc """
  Rebuilding the conversation window from the transcript (design §10.5).

  These assert the *shape handed to the model*, because that is the thing that
  can silently drift: a rehydrated history that looks right in the database and
  wrong in the request is exactly the failure the replay tier was built to
  catch, one layer down.
  """

  use Dobby.DataCase, async: true

  alias Dobby.Conversation
  alias Dobby.Conversation.Rehydrate
  alias Dobby.Utterance
  alias Jido.AI.Context

  defp speaker!(name) do
    {:ok, speaker} = Conversation.name_speaker(name)
    speaker
  end

  # Assert on the projection, never on `entries`. Entries are stored
  # newest-first internally and `to_messages/1` is what the model is handed —
  # testing the storage order would pin an implementation detail and pass while
  # the request went out backwards.
  defp projected(opts \\ []), do: opts |> Rehydrate.context() |> Context.to_messages()

  defp contents(opts \\ []), do: opts |> projected() |> Enum.map(& &1.content)

  test "an empty transcript rehydrates to an empty context, not an error" do
    context = Rehydrate.context()

    assert %Context{} = context
    assert Context.empty?(context)
  end

  test "user messages come back through Utterance.to_message/1" do
    greg = speaker!("greg")

    {:ok, _} =
      Conversation.append_utterance(Utterance.new("greg", "set the thermostat to 70"), greg)

    assert [message] = projected()
    assert message.role == :user

    # The single definition of the prefix, not a rebuilt copy of it — history
    # after a restart must be byte-identical to history before one.
    assert message.content ==
             Utterance.to_message(Utterance.new("greg", "set the thermostat to 70"))

    assert message.content == "[greg] set the thermostat to 70"
  end

  test "assistant replies come back unprefixed" do
    {:ok, _} = Conversation.append_reply("Done — main thermostat set to 70.")

    assert [message] = projected()
    assert message.role == :assistant
    assert message.content == "Done — main thermostat set to 70."
  end

  test "system lines stay out of the model's history" do
    greg = speaker!("greg")
    {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "hello"), greg)
    {:ok, _} = Conversation.append_system_line("main thermostat set to 70", %{"via" => "card"})

    # Device state reaches the model through the live <house> block (§6.3).
    # Replaying an old state change into conversation history would hand it a
    # second, staler source of truth for the one thing doctrine forbids it to
    # guess about.
    messages = projected()

    assert length(messages) == 1
    refute Enum.any?(messages, &(&1.content =~ "thermostat"))
  end

  test "keeps interleaved speakers distinguishable" do
    greg = speaker!("greg")
    sam = speaker!("sam")

    {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "thermostat to 70"), greg)
    {:ok, _} = Conversation.append_reply("Done — main thermostat set to 70.")
    {:ok, _} = Conversation.append_utterance(Utterance.new("sam", "is the printer on?"), sam)

    assert [
             "[greg] thermostat to 70",
             "Done — main thermostat set to 70.",
             "[sam] is the printer on?"
           ] = contents()
  end

  test "the window caps how much history is replayed" do
    greg = speaker!("greg")

    for n <- 1..10 do
      {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "line #{n}"), greg)
    end

    messages = projected(window: 4)

    assert length(messages) == 4
    # The newest end, in reading order.
    assert Enum.map(messages, & &1.content) == [
             "[greg] line 7",
             "[greg] line 8",
             "[greg] line 9",
             "[greg] line 10"
           ]
  end

  test "system lines do not eat the window" do
    greg = speaker!("greg")

    # A busy hour of card taps between two sentences should not cost Dobby the
    # conversation around them.
    {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "first"), greg)
    for n <- 1..12, do: {:ok, _} = Conversation.append_system_line("tap #{n}")
    {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "last"), greg)

    assert ["[greg] first", "[greg] last"] = contents(window: 4)
  end
end
