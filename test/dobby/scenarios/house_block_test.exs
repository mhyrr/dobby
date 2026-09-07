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

  import Ecto.Query
  import Jido.AI.Test

  alias Dobby.{Conversation, DobbyAgent, Repo, Rules, Utterance}
  alias Dobby.Conversation.Turn
  alias Dobby.Rules.Proposal

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
      probe = Map.fetch!(runtime_context, :probe)
      send(probe, {:house_request, messages})
      # The whole request, for the scenario that reads more than the block:
      # the tools the model is offered and the system prompt it is sent.
      send(probe, {:house_request_whole, %{request | messages: messages}})
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

  # TK-052. Two claims this codebase makes about every request and had never
  # asserted: the system prompt is byte-identical from one model turn to the
  # next, which is the whole reason the house block is not in it (§6.3 and
  # this transformer's moduledoc), and the model is offered exactly this
  # house's tools, not the library's.
  test "the whole request: one system prompt across turns, this house's tools, the block last" do
    eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)

    utterance = Utterance.new("greg", "is the thermostat still where I left it?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("Still 68°, set to 68°.")
      end

    assert {:ok, _reply} = DobbyAgent.say(utterance, probing(script))

    assert_receive {:house_request_whole, first}, 5_000
    assert_receive {:house_request_whole, second}, 5_000

    # The system prompt is the first message, and it is the same bytes on the
    # second turn as on the first: the soul, then the doctrine, and nothing
    # per turn in it. Whether the provider's cache honours that is measured
    # by the eval tier; that it could is asserted here.
    [%{role: :system, content: prompt} | _] = first.messages
    [%{role: :system, content: ^prompt} | _] = second.messages
    assert prompt =~ "You act only through your tools"

    # The tools are this house's closed set, by name, resolved once for the
    # request and the same on every turn of it. The runner hands them over
    # keyed by tool name.
    assert Enum.sort(Map.keys(first.tools)) ==
             Dobby.Home.tools() |> Enum.map(& &1.name()) |> Enum.sort()

    assert first.tools == second.tools

    # And on both turns the block is the message before the utterance. On the
    # first the utterance is last; on the second the request's own tool call
    # and its result follow it, which is the traffic the window keeps.
    Enum.each([first, second], fn request ->
      spoken = Enum.find_index(request.messages, &(text(&1) == Utterance.to_message(utterance)))
      assert spoken, "the utterance is not in the request"
      assert String.starts_with?(text(Enum.at(request.messages, spoken - 1)), "<house>")
    end)

    assert List.last(first.messages) |> text() == Utterance.to_message(utterance)
    assert [%{role: :assistant}, %{role: :tool}] = Enum.take(second.messages, -2)
  end

  # TK-054. The observables lived only in `list_rules`'s result, so the doctrine
  # asked for that call before every proposal and every rule request paid a
  # model turn to read a list that never changed. The block carries it now, in
  # the tool's own words, and a proposal is two turns.
  test "the block names what each device can be watched for, in the words list_rules uses" do
    eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)

    utterance = Utterance.new("greg", "what can you keep an eye on?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        answer("The thermostat's temperature, its setpoint, and its mode.")
      end

    assert {:ok, _reply} = DobbyAgent.say(utterance, probing(script))
    assert_receive {:house_request, messages}, 5_000
    [_spoken, house | _earlier] = Enum.reverse(messages)

    line = device_line(text(house), @thermostat)

    assert line =~
             "watches: current_temperature_f (number), " <>
               "hvac_mode (off/heat/cool/heat_cool/auto/dry/fan_only), " <>
               "target_temperature_f (number)"

    # The same words the tool returns, so the model that reads the block and
    # the model that reads the tool see one vocabulary.
    {:ok, listed} = Dobby.Tools.ListRules.run(%{}, %{})
    %{observables: observables} = Enum.find(listed.vocabulary, &(&1.device == @thermostat))
    assert observables[:hvac_mode] == ~w(off heat cool heat_cool auto dry fan_only)
    assert observables[:current_temperature_f] == "number"

    # And a house with nothing standing says so, in a few words.
    assert text(house) =~ "Standing rules: none."
    refute text(house) =~ "Standing notices"
    assert Trace.tool_calls() == []
  end

  test "the block lists the standing rules by id, paused ones marked, and the notices standing" do
    writable_house!()
    eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)

    assert {:ok, _} = Dobby.Rules.save(rule("cold-room", "Cold room", "lt", 70))
    assert {:ok, _} = Dobby.Rules.save(rule("hot-room", "Hot room", "gt", 80))
    assert {:ok, _} = Dobby.Rules.set_enabled("hot-room", false)

    # 68 is below 70 with no duration to wait out, so the cold room is a
    # standing notice by the time the model is asked anything.
    :ok = Dobby.Rules.Watcher.check()
    assert [%{rule_id: "cold-room", acknowledged: false}] = Dobby.Rules.notices()

    utterance = Utterance.new("greg", "pause the cold room rule")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("set_rule_enabled", %{"id" => "cold-room", "enabled" => false})
        answer("Paused the cold room rule.")
      end

    assert {:ok, _reply} = DobbyAgent.say(utterance, probing(script))
    assert_receive {:house_request, messages}, 5_000
    [_spoken, house | _earlier] = Enum.reverse(messages)

    assert text(house) =~
             ~s(Standing rules: cold-room "Cold room"; hot-room "Hot room" \(paused\).)

    assert text(house) =~ "Standing notices: cold-room."

    # Identified from the block, so the pause is the only call: no list first.
    assert Trace.tool_calls() == ["set_rule_enabled"]

    assert [%{id: "cold-room", enabled: false}, %{id: "hot-room", enabled: false}] =
             Dobby.Rules.list()
  end

  # TK-053. The window forgets earlier requests' tool rows and keeps what was
  # said, and the one thing a tool row carried that a later turn needs — a
  # proposal id — reaches the model from the block instead. Two household
  # turns through the thread's own path, with the probe on both.
  test "a proposal id outlives the tool result that made it, and the tool rows do not" do
    writable_house!()
    eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)
    {:ok, speaker} = Conversation.name_speaker("greg")

    said = Utterance.new("greg", "Tell me if the main room drops below 68.")

    proposing =
      expect_react do
        user(Utterance.to_message(said))

        call("propose_rule", %{
          "id" => "cold-room",
          "name" => "Cold room",
          "device" => @thermostat,
          "kind" => "state",
          "attribute" => "current_temperature_f",
          "operator" => "lt",
          "number_value" => 68,
          "duration" => 0,
          "duration_unit" => "seconds"
        })

        answer("I'll tell the house as soon as the main room is below 68°F. Shall I save that?")
      end

    Turn.run(said, speaker, probing(proposing))
    assert_receive {:house_request, _proposing_turn}, 5_000
    assert_receive {:house_request, _answering_turn}, 5_000
    assert [proposal] = Repo.all(from(p in Proposal, where: p.status == "proposed"))

    agreed = Utterance.new("greg", "Yes, save that.")

    # The confirmation, with the id the block gave. No slot stands in for the
    # previous request's tool turn: the script indexes the request it answers,
    # and the window has forgotten that turn.
    confirming =
      expect_react do
        user(Utterance.to_message(agreed))
        call("confirm_rule", %{"id" => proposal.id})
        answer("The cold-room rule is watching.")
      end

    Trace.reset()
    Turn.run(agreed, speaker, probing(confirming))
    assert_receive {:house_request, messages}, 5_000

    # What was said, and nothing that was fetched to say it.
    refute Enum.any?(messages, &(&1[:role] == :tool))
    refute Enum.any?(messages, &(is_list(&1[:tool_calls]) and &1[:tool_calls] != []))
    assert Enum.any?(messages, &(text(&1) =~ "Shall I save that?"))
    assert Enum.any?(messages, &(text(&1) == Utterance.to_message(said)))

    # And the id, in the block, on the turn the household said yes.
    [_spoken, house | _earlier] = Enum.reverse(messages)

    assert text(house) =~
             "Rule proposals awaiting agreement, by proposal id for confirm_rule: " <>
               ~s(#{proposal.id} — rule cold-room "Cold room".)

    assert Trace.tool_calls() == ["confirm_rule"]
    assert [%{id: "cold-room"}] = Rules.list()
  end

  defp rule(id, name, operator, value) do
    %{
      "id" => id,
      "name" => name,
      "device" => @thermostat,
      "kind" => "state",
      "attribute" => "current_temperature_f",
      "operator" => operator,
      "value" => value,
      "duration_seconds" => 0
    }
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
