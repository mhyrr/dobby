defmodule Dobby.Scenarios.RulesHistoryTest do
  use Dobby.RigCase, async: false
  import Jido.AI.Test
  import Ecto.Query
  alias Dobby.{Conversation, Repo, Rules, Utterance}
  alias Dobby.Conversation.Turn
  alias Dobby.Rules.Proposal

  test "two household turns install a rule, which reports and can be queried without inference" do
    writable_house!()
    seed_house(%{"climate.main_floor" => thermostat_entity(current: 66, target: 68)})
    {:ok, speaker} = Conversation.name_speaker("greg")

    said =
      Utterance.new(
        "greg",
        "Tell me immediately if the main room is below 68 degrees Fahrenheit."
      )

    proposing =
      expect_react do
        user(Utterance.to_message(said))
        call("list_rules", %{})

        call("propose_rule", %{
          "id" => "cold-room",
          "name" => "Cold room",
          "device" => "thermostat:main",
          "kind" => "state",
          "attribute" => "current_temperature_f",
          "operator" => "lt",
          "number_value" => 68,
          "duration" => 0,
          "duration_unit" => "seconds"
        })

        answer("I'll tell the house when the main room is below 68°F. Shall I save that rule?")
      end

    Turn.run(said, speaker, react_opts(proposing))
    assert [proposal] = Repo.all(from(p in Proposal, where: p.status == "proposed"))
    assert proposal.entry["source"] == said.text
    assert Rules.list() == []
    assert Rules.notices() == []

    agreed = Utterance.new("greg", "Yes, save that rule.")

    # ReActScript indexes responses by all assistant tool turns in the retained
    # conversation, not just those since the latest user message. The first two
    # slots account for list_rules and propose_rule from the previous request;
    # they must not execute again. Keep the agent running to exercise live apply.
    confirming =
      expect_react do
        user(Utterance.to_message(agreed))
        call("list_rules", %{})
        call("list_rules", %{})
        call("confirm_rule", %{"id" => proposal.id})
        answer("The cold-room rule is watching.")
      end

    agent = Dobby.Jido.whereis("dobby")
    assert is_pid(agent)
    Trace.reset()
    Turn.run(agreed, speaker, react_opts(confirming))
    assert Trace.tool_calls() == ["confirm_rule"]
    assert Repo.get!(Proposal, proposal.id).status == "applied"
    assert Dobby.Jido.whereis("dobby") == agent
    assert [%{id: "cold-room"}] = Rules.list()
    Trace.reset()
    :ok = Dobby.Rules.Watcher.check()
    assert [%{rule_id: "cold-room"}] = Rules.notices()
    assert Trace.llm_calls() == []
    assert Trace.ha_calls() == []
    assert {:ok, %{count: 1}} = Dobby.History.query(%{kind: "rule_breached"})
  end

  test "a rule proposed in this message cannot be confirmed in the same message" do
    writable_house!()
    seed_house(%{"climate.main_floor" => thermostat_entity(current: 66, target: 68)})
    {:ok, speaker} = Conversation.name_speaker("greg")

    said = Utterance.new("greg", "Tell me if the main room drops below 68.")

    # The two halves of one request, as the queue runs them: the words land in
    # the thread, then Dobby answers them. `Turn.record/2` is where the request
    # id comes from, and holding it is the only way to put a proposal *inside*
    # the message the model is about to answer.
    #
    # The proposal is made by `Dobby.Rules.propose/2` — the same function
    # `propose_rule` calls, with the same request id it would pass. The model's
    # own call cannot be scripted next to the confirm: `expect_react` fixes a
    # tool call's arguments before the turn runs, and the proposal id does not
    # exist until it has.
    {:ok, request_id} = Turn.record(said, speaker)

    {:ok, proposal} =
      Rules.propose(
        %{
          "id" => "cold-room",
          "name" => "Cold room",
          "device" => "thermostat:main",
          "kind" => "state",
          "attribute" => "current_temperature_f",
          "operator" => "lt",
          "value" => 68.0,
          "duration_seconds" => 0,
          "source" => said.text
        },
        actor: "greg",
        via: :conversation,
        request_id: request_id
      )

    eager =
      expect_react do
        user(Utterance.to_message(said))
        call("confirm_rule", %{"id" => proposal.id})
        answer("That's written down. Say the word and I'll start watching.")
      end

    Turn.answer(said, speaker, request_id, react_opts(eager))

    assert Trace.tool_calls() == ["confirm_rule"]
    assert Rules.list() == []
    assert Rules.notices() == []
    assert Repo.get!(Proposal, proposal.id).status == "proposed"
    assert Repo.get!(Proposal, proposal.id).confirmed_by == nil

    # The refusal is an observation the model has to account for, not a silent
    # no-op: it is in the record of this request, in the household's words.
    assert [recorded] =
             Enum.filter(
               Dobby.Activity.for_request(request_id),
               &(&1.kind == "tool_call" and &1.action == "confirm_rule")
             )

    assert inspect(recorded.result) =~ "wait for the household to agree in a later message"
    assert Trace.ha_calls() == []
  end

  test "the exported rule schema does not describe typed values or windows as strings" do
    schema = Jido.Action.Schema.to_json_schema(Dobby.Tools.ProposeRule.schema())
    assert schema["properties"]["number_value"]["type"] == "number"
    assert schema["properties"]["boolean_value"]["type"] == "boolean"
    assert schema["properties"]["window_days"]["items"]["type"] == "integer"
  end
end
