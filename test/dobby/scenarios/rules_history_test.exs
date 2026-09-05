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

  test "the exported rule schema does not describe typed values or windows as strings" do
    schema = Jido.Action.Schema.to_json_schema(Dobby.Tools.ProposeRule.schema())
    assert schema["properties"]["number_value"]["type"] == "number"
    assert schema["properties"]["boolean_value"]["type"] == "boolean"
    assert schema["properties"]["window_days"]["items"]["type"] == "integer"
  end
end
