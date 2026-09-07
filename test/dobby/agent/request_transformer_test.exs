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
    test "leaves a short conversation's words alone" do
      messages =
        Enum.flat_map(0..2, fn i ->
          [%{role: :user, content: "[greg] turn #{i}"}, %{role: :assistant, content: "right"}]
        end)

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
      # The transformer runs before a model call, so the messages it sees end
      # at a person speaking or at a tool result — never between a call and
      # its answer. Lengths that would cut there are not a request shape.
      for length <- 40..80, messages = conversation(length), not mid_call?(messages) do
        windowed = RequestTransformer.window(messages)

        assert_no_orphans(windowed, "at #{length} messages")
        assert %{role: :user} = List.first(windowed)
      end
    end

    # One request with more of its own tool traffic than the window allows.
    # It cannot be cut from the middle, and corrupting a real request to save
    # tokens would be the wrong trade.
    test "sends a single oversized turn whole rather than breaking it" do
      long_turn =
        [%{role: :user, content: "[greg] do the big thing"}] ++
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

  # TK-053. Tool traffic is the largest thing in the window and the least
  # worth remembering: a `list_rules` result is 624 tokens with no rules in it,
  # and every `history` row set rode on every following turn until it fell
  # out. What was said is kept; what was fetched to say it is forgotten, and
  # the record still holds it.
  describe "what the window remembers of earlier requests" do
    test "keeps what was said and drops the tool rows, the pair together" do
      windowed = RequestTransformer.window(conversation(12))

      refute Enum.any?(windowed, &(role(&1) == :tool))
      refute Enum.any?(windowed, &tool_calls?/1)

      # The words, in the order they were said: nothing but the current
      # request has a tool row left, and it has none of its own here.
      assert Enum.map(windowed, &{role(&1), &1.content}) == [
               {:user, "[greg] turn 0"},
               {:assistant, "it is 68"},
               {:user, "[greg] turn 1"},
               {:assistant, "right"},
               {:user, "[greg] turn 2"},
               {:assistant, "it is 68"},
               {:user, "[greg] turn 3"},
               {:assistant, "right"}
             ]
    end

    test "the current request keeps its own tool traffic, which the model asked for" do
      # Mid-loop: the person spoke, the model called a tool, the result is
      # back, and the model has not answered yet. This is the request the
      # transformer is building, and the result is the whole reason for the
      # next model turn.
      current = [
        %{role: :user, content: "[greg] who set the thermostat?"},
        %{role: :assistant, content: nil, tool_calls: [%{id: "call_now"}]},
        %{role: :tool, tool_call_id: "call_now", name: "history", content: "rows"}
      ]

      windowed = RequestTransformer.window(conversation(8) ++ current)

      assert Enum.take(windowed, -3) == current
      assert_no_orphans(windowed, "a request mid-loop")
      assert Enum.count(windowed, &(role(&1) == :tool)) == 1
    end

    test "words said beside a tool call stay, without the call" do
      earlier = [
        %{role: :user, content: "[greg] is it warm?"},
        %{role: :assistant, content: "Checking.", tool_calls: [%{id: "call_a"}]},
        %{role: :tool, tool_call_id: "call_a", name: "thermostat_get_status", content: "68"},
        %{role: :assistant, content: "It is 68."}
      ]

      current = [%{role: :user, content: "[greg] and now?"}]

      assert RequestTransformer.window(earlier ++ current) == [
               %{role: :user, content: "[greg] is it warm?"},
               %{role: :assistant, content: "Checking."},
               %{role: :assistant, content: "It is 68."},
               %{role: :user, content: "[greg] and now?"}
             ]
    end

    test "an earlier house block is not conversation" do
      earlier = [
        %{role: :user, content: "<house>\nold roster\n</house>"},
        %{role: :user, content: "[greg] hello"},
        %{role: :assistant, content: "Hello, Greg."}
      ]

      current = [
        %{role: :user, content: "<house>\nnewer roster\n</house>"},
        %{role: :user, content: "[greg] still there?"}
      ]

      windowed = RequestTransformer.window(earlier ++ current)

      refute Enum.any?(windowed, &String.starts_with?(&1.content || "", "<house>"))
      assert List.last(windowed) == %{role: :user, content: "[greg] still there?"}
      assert length(windowed) == 3
    end

    test "the cap applies to what is left, and still starts at somebody speaking" do
      # 402 ends on a plain exchange, so the current request has no tool rows
      # of its own to keep and the whole window should be words.
      windowed = RequestTransformer.window(conversation(402))

      assert length(windowed) <= Conversation.window()
      assert %{role: :user} = List.first(windowed)
      refute Enum.any?(windowed, &(role(&1) == :tool))
    end

    # jido_ai appends its own user message when the model repeats a tool call
    # (`@cycle_warning`, react/runner.ex). It is not a household utterance and
    # must not start a request: the review of 2026-09-07 traced the trim
    # reading it as one and stripping the in-flight request's own results,
    # then telling the model to answer from results it no longer had.
    test "jido's cycle warning does not start a new request" do
      current = [
        %{role: :user, content: "[greg] who set the thermostat?"},
        %{role: :assistant, content: nil, tool_calls: [%{id: "c1"}]},
        %{role: :tool, tool_call_id: "c1", name: "history", content: "rows"},
        %{role: :assistant, content: nil, tool_calls: [%{id: "c2"}]},
        %{role: :tool, tool_call_id: "c2", name: "history", content: "rows"},
        %{role: :user, content: "You already called the same tool(s) with identical parameters."}
      ]

      earlier = [%{role: :user, content: "[greg] hello"}, %{role: :assistant, content: "Hi."}]

      assert RequestTransformer.window(earlier ++ current) == earlier ++ current
    end

    test "the block is injected before the utterance even when jido's warning is last" do
      # Through the real transformer with an empty world model: the block
      # sits before what the person said, not before jido's message.
      messages = [
        %{role: :user, content: "[greg] who set the thermostat?"},
        %{role: :assistant, content: nil, tool_calls: [%{id: "c1"}]},
        %{role: :tool, tool_call_id: "c1", name: "history", content: "rows"},
        %{role: :user, content: "You already called the same tool(s)."}
      ]

      {:ok, %{messages: built}} =
        RequestTransformer.transform_request(%{messages: messages}, %{}, %{}, %{})

      [block, spoken | _rest] = built
      assert String.starts_with?(block.content, "<house>")
      assert spoken.content == "[greg] who set the thermostat?"
      assert List.last(built).content == "You already called the same tool(s)."
    end

    test "string-keyed messages are read by the same rule as atom-keyed ones" do
      earlier = [
        %{"role" => "user", "content" => "[greg] is it warm?"},
        %{"role" => "assistant", "content" => nil, "tool_calls" => [%{id: "c"}]},
        %{"role" => "tool", "tool_call_id" => "c", "name" => "t", "content" => "68"},
        %{"role" => "assistant", "content" => "It is 68."}
      ]

      current = [%{role: :user, content: "[greg] and now?"}]
      windowed = RequestTransformer.window(earlier ++ current)

      assert windowed == [
               %{"role" => "user", "content" => "[greg] is it warm?"},
               %{"role" => "assistant", "content" => "It is 68."},
               %{role: :user, content: "[greg] and now?"}
             ]

      assert_no_orphans(windowed, "string keys")
    end

    # A reasoning model's message carries its chain of thought as a content
    # part; on the models in force that block is larger than the tool result
    # the trim exists to drop. What was said stays; what was thought goes.
    test "an earlier turn's thinking goes with its tool call, and its words stay" do
      earlier = [
        %{role: :user, content: "[greg] set it to 70"},
        %{
          role: :assistant,
          content: [
            %{type: :thinking, thinking: String.duplicate("hmm ", 200)},
            %{type: :text, text: "Setting it to 70, Greg."}
          ],
          tool_calls: [%{id: "c"}],
          reasoning_details: [%{type: "reasoning.text", text: "..."}]
        },
        %{role: :tool, tool_call_id: "c", name: "thermostat_set_temperature", content: "ok"},
        %{
          role: :assistant,
          content: [%{type: :thinking, thinking: "done?"}, %{type: :text, text: "Done."}],
          tool_calls: nil
        }
      ]

      current = [%{role: :user, content: "[greg] thanks"}]

      assert RequestTransformer.window(earlier ++ current) == [
               %{role: :user, content: "[greg] set it to 70"},
               %{role: :assistant, content: [%{type: :text, text: "Setting it to 70, Greg."}]},
               %{role: :assistant, content: [%{type: :text, text: "Done."}]},
               %{role: :user, content: "[greg] thanks"}
             ]
    end

    # The same policy at the other moment (`Dobby.Conversation.window/0`):
    # boot rehydration replays only what people and Dobby said, so what boot
    # remembers is already in the shape the window keeps, and the window
    # leaves it alone.
    test "what boot remembers is already in the shape the window keeps" do
      remembered =
        Enum.flat_map(0..9, fn i ->
          [%{role: :user, content: "[greg] turn #{i}"}, %{role: :assistant, content: "ok #{i}"}]
        end)

      assert RequestTransformer.window(remembered) == remembered
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp role(%{role: role}), do: role

  defp mid_call?(messages) do
    case List.last(messages) do
      %{tool_calls: calls} when is_list(calls) -> calls != []
      _other -> false
    end
  end

  defp tool_calls?(%{tool_calls: calls}) when is_list(calls), do: calls != []
  defp tool_calls?(_message), do: false

  # Turns as the ReAct strategy actually accumulates them: somebody speaks,
  # the model calls a tool, the result comes back, the model answers. Every
  # other turn is plain talk, so the cut has both shapes to land in.
  defp conversation(count) do
    Stream.unfold(0, fn i ->
      turn =
        if rem(i, 2) == 0 do
          [
            %{role: :user, content: "[greg] turn #{i}"},
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
          [%{role: :user, content: "[greg] turn #{i}"}, %{role: :assistant, content: "right"}]
        end

      {turn, i + 1}
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(count)
  end

  # Both directions: a result whose call is gone, and a call whose result is
  # gone. Providers reject either, and the trim can only be trusted if it
  # never produces the second while guarding against the first.
  defp assert_no_orphans(messages, context) do
    offered =
      messages
      |> Enum.flat_map(fn message ->
        case Map.get(message, :tool_calls, Map.get(message, "tool_calls")) do
          calls when is_list(calls) -> Enum.map(calls, & &1.id)
          _none -> []
        end
      end)
      |> MapSet.new()

    answered =
      messages
      |> Enum.map(&(Map.get(&1, :tool_call_id) || Map.get(&1, "tool_call_id")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    for id <- answered do
      assert MapSet.member?(offered, id),
             "#{context}: tool result #{id} has no matching tool_calls in the window"
    end

    for id <- offered do
      assert MapSet.member?(answered, id),
             "#{context}: tool call #{id} has no result in the window"
    end
  end
end
