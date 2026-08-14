defmodule Dobby.Scenarios.ThermostatSetpointTest do
  @moduledoc """
  Scenario 1: "Dobby, turn the thermostat to 70."

  The whole spine, with only the model and Home Assistant faked: a real
  utterance envelope, the real ReAct loop, the real tool, the real thermostat
  agent, a real `HACall` directive, and the real physical confirm loop coming
  back the other way.

  ## Why the script is threaded explicitly

  `Jido.AI.Test.expect_react/1` registers its script against
  `Process.group_leader()`, which matches when the agent is started by the
  test. Dobby's agents are started by the application supervisor at boot —
  that is the design (§5), and it means their group leader is not the test's.
  So every replay scenario passes `react_opts(script)` down through the ask,
  which is the path `Jido.AI.Test` documents for agents outside the test tree.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.{DobbyAgent, Utterance}

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
    Trace.reset()
    :ok
  end

  test "one tool call, one HA call, and a reply composed from the real result" do
    utterance = Utterance.new("greg", "Dobby, turn the thermostat to 70")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 70})
        answer("Set the main thermostat to 70°.")
      end

    assert {:ok, result} = DobbyAgent.say(utterance, react_opts(script))

    # The reply is the model's, composed inside the loop — there is no
    # template anywhere in this path.
    assert result =~ "70"

    # Exactly one service call reached Home Assistant, and it is the one the
    # thermostat agent decided on rather than anything the model wrote.
    assert [
             %HACall{
               domain: "climate",
               service: "set_temperature",
               entity_id: @entity,
               data: %{temperature: 70.0}
             }
           ] = Fake.trace()

    # And the setpoint arrived back through the confirm loop rather than being
    # assumed by whoever issued the command.
    assert_receive %Jido.Signal{type: "dobby.device.state_changed", data: %{snapshot: snapshot}},
                   2_000

    assert snapshot.target_temperature_f == 70.0
    assert agent_state(@thermostat).target_temperature_f == 70.0

    # The emitted pattern, which is the thing the replay tier is pinning.
    # One tool, one service call, and two model turns — the price design §6.5
    # predicted for an actuating request, now measured instead of assumed.
    assert Trace.tool_calls() == ["thermostat_set_temperature"]
    assert Trace.counts() == %{llm: 2, tool: 1, ha: 1}

    assert {"thermostat:main", "thermostat.set_temperature"} in Trace.signals()
    assert {"thermostat:main", "ha.state_changed"} in Trace.signals()
    assert {"dobby", "dobby.device.state_changed"} in Trace.signals()
  end

  test "the house is injected before the utterance, not onto it" do
    # Collision found in the harness source: ReActScript matches a script to a
    # request by exact string equality against the *last* user message. If the
    # roster and device snapshot were appended to the user's own message — as
    # the design originally specified — this script would not match, and every
    # scenario would have to spell out the whole rendered block.
    utterance = Utterance.new("maya", "what is the thermostat at?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("It's 68° and set to 68°.")
      end

    assert {:ok, _result} = DobbyAgent.say(utterance, react_opts(script))

    # A read is answered from device-agent state; nothing went to HA.
    assert Fake.trace() == []
    assert Trace.ha_calls() == []
    assert Trace.tool_calls() == ["thermostat_get_status"]
  end

  test "an unscripted turn fails loudly instead of reaching a real model" do
    # The mistake this guard exists for: a scenario that forgets to thread
    # `react_opts(script)`. jido_ai's runner treats "no script matched" as
    # permission to call the provider for real, so without the closed-port
    # base_url in config/test.exs this line would bill someone.
    utterance = Utterance.new("greg", "nobody scripted this")

    assert {:error, _reason} = DobbyAgent.say(utterance, timeout: 5_000)

    assert Trace.ha_calls() == []
  end

  test "the world model knows the house before anyone says anything" do
    # Device agents emitted state on boot, and that fan-out has two consumers:
    # PubSub for the thread, and DobbyAgent directly. Nothing seeded this.
    #
    # `eventually` because the two consumers are fed by an async stream: the
    # thread's copy arriving is not evidence that DobbyAgent's has.
    world_model = eventually(fn -> agent_state(DobbyAgent.id()) |> Map.get(:world_model) end)

    assert %{@thermostat => snapshot} = world_model
    assert snapshot.available
    assert snapshot.current_temperature_f == 68

    rendered = DobbyAgent.RequestTransformer.render(world_model)
    assert rendered =~ @thermostat
    assert rendered =~ "main thermostat"
    assert rendered =~ "downstairs thermostat"
    assert rendered =~ "68°F"
  end
end
