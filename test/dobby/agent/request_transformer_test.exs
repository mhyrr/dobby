defmodule Dobby.DobbyAgent.RequestTransformerTest do
  @moduledoc """
  What one request actually carries (`TK-007`).

  `Jido.AI.Context` says of itself "no policies, no windowing, just data", and
  both callers inside jido_ai project it with no limit — so the transformer is
  the only thing standing between a house that has been talking for a week and
  a week of conversation on every request.

  The assertion that matters is not the length. It is that the cut never leaves
  a tool result whose call is not in the window: providers reject that outright,
  and it is a failure that could only ever appear after a house had been talking
  long enough to need trimming, which is the worst possible time to find out.
  """

  use ExUnit.Case, async: true

  alias Dobby.Conversation
  alias Dobby.DobbyAgent.RequestTransformer

  describe "the window" do
    test "leaves a short conversation alone" do
      messages = conversation(6)

      assert RequestTransformer.window(messages) == messages
    end

    test "caps a long one at the house's window" do
      windowed = RequestTransformer.window(conversation(400))

      assert length(windowed) <= Conversation.window()
      assert length(windowed) > Conversation.window() - 4
    end

    test "keeps the system prompt, which is not conversation" do
      system = %{role: :system, content: "you are Dobby"}

      windowed = RequestTransformer.window([system | conversation(400)])

      assert [^system | rest] = windowed
      assert length(rest) <= Conversation.window()
    end

    test "starts at somebody speaking" do
      windowed = RequestTransformer.window(conversation(400))

      assert %{role: :user} = List.first(windowed)
    end

    # The trap. A turn is assistant(tool_calls) then tool(result), and cutting
    # between them opens the request with an answer to a question that is not
    # there. Every offset is checked because the cut lands wherever the
    # arithmetic puts it, and only some offsets land mid-turn.
    test "never orphans a tool result, wherever the cut lands" do
      for length <- 40..80 do
        windowed = RequestTransformer.window(conversation(length))

        assert_no_orphans(windowed, "at #{length} messages")
        assert %{role: :user} = List.first(windowed)
      end
    end

    # One request with more of its own tool traffic than the window allows.
    # It cannot be cut from the middle, and corrupting a real request to save
    # tokens would be the wrong trade.
    test "sends a single oversized turn whole rather than breaking it" do
      long_turn =
        [%{role: :user, content: "do the big thing"}] ++
          Enum.flat_map(1..60, fn i ->
            [
              %{role: :assistant, content: nil, tool_calls: [%{id: "call_#{i}"}]},
              %{role: :tool, tool_call_id: "call_#{i}", name: "t", content: "ok"}
            ]
          end)

      # The only user message is the first, so no legal cut fits the window.
      windowed = RequestTransformer.window(long_turn)

      assert windowed == long_turn
      assert_no_orphans(windowed, "an oversized single turn")
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Turns as the ReAct strategy actually accumulates them: somebody speaks,
  # the model calls a tool, the result comes back, the model answers. Every
  # other turn is plain talk, so the cut has both shapes to land in.
  defp conversation(count) do
    Stream.unfold(0, fn i ->
      turn =
        if rem(i, 2) == 0 do
          [
            %{role: :user, content: "turn #{i}"},
            %{role: :assistant, content: nil, tool_calls: [%{id: "call_#{i}"}]},
            %{
              role: :tool,
              tool_call_id: "call_#{i}",
              name: "thermostat_get_status",
              content: "68"
            },
            %{role: :assistant, content: "it is 68"}
          ]
        else
          [%{role: :user, content: "turn #{i}"}, %{role: :assistant, content: "right"}]
        end

      {turn, i + 1}
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(count)
  end

  defp assert_no_orphans(messages, context) do
    offered =
      messages
      |> Enum.flat_map(fn
        %{tool_calls: calls} when is_list(calls) -> Enum.map(calls, & &1.id)
        _other -> []
      end)
      |> MapSet.new()

    for %{role: :tool, tool_call_id: id} <- messages do
      assert MapSet.member?(offered, id),
             "#{context}: tool result #{id} has no matching tool_calls in the window"
    end
  end
end
