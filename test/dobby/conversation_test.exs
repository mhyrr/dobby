defmodule Dobby.ConversationTest do
  @moduledoc """
  The transcript and the people in it (design §10.1, §10.2).
  """

  use Dobby.DataCase, async: true

  alias Dobby.Conversation
  alias Dobby.Utterance

  describe "name_speaker/1" do
    test "creates a speaker the first time and returns the same one after" do
      assert {:ok, greg} = Conversation.name_speaker("greg")
      assert {:ok, again} = Conversation.name_speaker("greg")

      assert greg.id == again.id
    end

    test "resolves case-insensitively, so one person is one row" do
      assert {:ok, greg} = Conversation.name_speaker("greg")
      assert {:ok, shouting} = Conversation.name_speaker("GREG")

      assert greg.id == shouting.id
      assert [_only_one] = Conversation.list_speakers()
    end

    test "trims, because the name comes from a text box" do
      assert {:ok, speaker} = Conversation.name_speaker("  sam  ")
      assert speaker.name == "sam"
    end

    test "refuses an empty name" do
      assert {:error, changeset} = Conversation.name_speaker("   ")
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "the thread" do
    setup do
      {:ok, greg} = Conversation.name_speaker("greg")
      %{greg: greg}
    end

    test "records an utterance with its speaker and channel", %{greg: greg} do
      utterance = Utterance.new("greg", "set the thermostat to 70")

      assert {:ok, message} = Conversation.append_utterance(utterance, greg)
      assert message.role == :user
      assert message.channel == :web
      assert message.text == "set the thermostat to 70"
      assert message.speaker_id == greg.id
    end

    test "records a reply with no speaker" do
      assert {:ok, message} = Conversation.append_reply("Done — main thermostat set to 70.")
      assert message.role == :assistant
      assert is_nil(message.speaker_id)
    end

    test "records a system line with its structured half" do
      meta = %{"device" => "thermostat:main", "action" => "set_temperature", "via" => "card"}

      assert {:ok, message} = Conversation.append_system_line("main thermostat set to 70", meta)
      assert message.role == :system
      assert message.meta == meta
    end

    test "refuses an utterance with nobody attached" do
      # Flat trust means identity never gates, but it does have to exist: a
      # user message with no speaker is a bug in the identity plug, and the
      # thread is the wrong place to discover it.
      changeset =
        Dobby.Conversation.Message.changeset(%Dobby.Conversation.Message{}, %{
          role: :user,
          text: "who am I"
        })

      refute changeset.valid?
      assert %{speaker_id: _} = errors_on(changeset)
    end

    test "reads back oldest first, however it was written", %{greg: greg} do
      {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "first"), greg)
      {:ok, _} = Conversation.append_reply("second")
      {:ok, _} = Conversation.append_system_line("third")

      assert ["first", "second", "third"] = Enum.map(Conversation.list_messages(), & &1.text)
    end

    test "recent/1 takes from the newest end and still returns oldest first", %{greg: greg} do
      for n <- 1..5 do
        {:ok, _} = Conversation.append_utterance(Utterance.new("greg", "line #{n}"), greg)
      end

      assert ["line 3", "line 4", "line 5"] = Enum.map(Conversation.recent(3), & &1.text)
    end
  end
end
