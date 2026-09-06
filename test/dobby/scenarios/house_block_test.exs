defmodule Dobby.Scenarios.HouseBlockTest do
  @moduledoc """
  What the model was actually told about the house.

  Every other scenario checks the house block by calling
  `Dobby.DobbyAgent.RequestTransformer.render/1` on a world model the test
  fetched for itself. That proves the renderer works and proves nothing at all
  about the request. For the whole life of this codebase the transformer read
  the world model off the wrong argument and rendered every device as "state
  not yet known", and no replay scenario could see it, because no replay
  scenario looked at the messages the runner built. The model could see it: it
  started calling `*_get_status` to learn what the block was supposed to have
  told it, and the eval tier paid for the turn.

  So this file reads the real thing. `ask_sync` accepts a per-request
  `:request_transformer` — `Jido.AI.Request.create_and_send/3` puts it on the
  start payload, and `resolve_request_transformer/2`
  (`deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:2468`) prefers it over
  the agent's own. The scenario substitutes this module, which delegates
  straight to `Dobby.DobbyAgent.RequestTransformer` and forwards whatever came
  back. Nothing is recomputed here, so everything asserted below is what
  production produced.

  The test process reaches the probe through `:tool_context`, which jido_ai
  merges into the runtime context the transformer's fourth argument carries
  (`react/strategy.ex:699`) — the argument this file exists to pin.

  The test module is itself the transformer. One module per file is the house
  rule, and a probe used by one file has no business in `test/support`.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.{DobbyAgent, Utterance}

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
    Trace.reset()
    :ok
  end

  @impl true
  def transform_request(request, state, config, runtime_context) do
    result =
      DobbyAgent.RequestTransformer.transform_request(request, state, config, runtime_context)

    with {:ok, %{messages: messages}} <- result do
      send(Map.fetch!(runtime_context, :probe), {:house_request, messages})
    end

    result
  end

  test "the block the model is sent carries the state the house observed" do
    # The world model is fed by the same async fan-out the thread is, so it
    # arrives eventually and not on a schedule this test controls (§7).
    world_model = eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)
    assert %{@thermostat => snapshot} = world_model
    assert snapshot.current_temperature_f == 68

    utterance = Utterance.new("maya", "what is the thermostat at?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        answer("It's 68° and set to 68°.")
      end

    assert {:ok, _reply} = DobbyAgent.say(utterance, probing(script))
    assert_receive {:house_request, messages}, 5_000

    # Placement, which the whole replay tier depends on: the block sits
    # immediately before the utterance, and the utterance stays last, so
    # `ReActScript` still matches a script by the raw user text.
    [spoken, house | _earlier] = Enum.reverse(messages)
    assert text(spoken) == Utterance.to_message(utterance)
    assert String.starts_with?(text(house), "<house>")

    # And the bug this file was written for: the roster carried the reading.
    line = device_line(text(house), @thermostat)
    assert line =~ "currently 68°F"
    refute line =~ "state not yet known"
  end

  test "every model turn in one request carries the same observed house" do
    eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)

    utterance = Utterance.new("greg", "is the thermostat still where I left it?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("Still 68°, set to 68°.")
      end

    assert {:ok, _reply} = DobbyAgent.say(utterance, probing(script))

    # Two model turns, so two requests, and the tool round between them must
    # not lose the snapshot: jido_ai threads the runtime context through the
    # loop and evolves it from tool state effects rather than rebuilding it
    # (`react/runner.ex:840`). A block that went blank on the second turn would
    # be the same class of bug one iteration later.
    assert_receive {:house_request, first}, 5_000
    assert_receive {:house_request, second}, 5_000

    Enum.each([first, second], fn messages ->
      blocks = Enum.filter(messages, &String.starts_with?(text(&1), "<house>"))
      assert [house] = blocks
      assert device_line(text(house), @thermostat) =~ "currently 68°F"
    end)

    assert Trace.tool_calls() == ["thermostat_get_status"]
    assert Trace.ha_calls() == []
  end

  # The script, this module as the transformer, and a way back to the test.
  defp probing(script) do
    react_opts(script)
    |> Keyword.put(:request_transformer, __MODULE__)
    |> Keyword.put(:tool_context, %{probe: self()})
  end

  defp device_line(house, device_id) do
    house
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "- #{device_id} "))
  end

  # A message's content is a string or a list of ReqLLM content parts,
  # depending on how it entered the context — the same two shapes
  # `ReActScript.normalize_content/1` allows for.
  defp text(%{content: content}), do: normalize(content)
  defp text(_message), do: ""

  defp normalize(content) when is_binary(content), do: content

  defp normalize(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> ""
    end)
  end

  defp normalize(_content), do: ""
end
