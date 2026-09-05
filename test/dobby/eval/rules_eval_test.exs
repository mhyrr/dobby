defmodule Dobby.Eval.RulesEvalTest do
  @moduledoc """
  Whether a model turns an intention into the right standing condition and
  respects the second-turn agreement boundary. These are billed evaluations,
  excluded from normal replay. No timer or device event invokes inference.
  """
  use Dobby.RigCase, async: false
  import Dobby.Eval
  import Ecto.Query
  alias Dobby.{Repo, Rules, Schedules}
  alias Dobby.Rules.Proposal
  @moduletag :eval
  @moduletag timeout: 180_000

  setup do
    writable_house!()
    seed_house(%{"climate.main_floor" => thermostat_entity(current: 66, target: 68)})
    Trace.reset()
    :ok
  end

  test "a threshold is proposed accurately and only watches after the next agreement" do
    %{reply: proposal_reply} =
      turn!(
        "greg",
        "Tell me if the main thermostat reports below 60 degrees Fahrenheit continuously for twenty minutes."
      )

    assert "propose_rule" in Trace.tool_calls()
    assert [proposal] = proposals()
    assert proposal.entry["kind"] == "state"
    assert proposal.entry["device"] == "thermostat:main"
    assert proposal.entry["attribute"] == "current_temperature_f"
    assert proposal.entry["operator"] == "lt"
    assert proposal.entry["value"] == 60
    assert proposal.entry["duration_seconds"] == 1200
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      proposal_reply,
      "Describes the proposed condition and asks for agreement; does not claim the rule is already watching."
    )

    %{reply: confirmation_reply} = turn!("greg", "Yes, save that rule.")
    assert [%{enabled: true, rule: rule}] = Rules.list()
    assert rule["duration_seconds"] == 1200
    assert rule["value"] == 60
    assert Trace.ha_calls() == []
    report("standing threshold and later agreement", confirmation_reply)
  end

  test "bedtime is clarified rather than guessed into a local window" do
    %{reply: reply} =
      turn!("greg", "Tell me if the main room stays below 60 for twenty minutes after bedtime.")

    assert Rules.list() == []
    assert proposals() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Asks what time bedtime means instead of choosing an hour for the household."
    )

    report("standing rule bedtime ambiguity", reply)
  end

  test "a combined condition is not split into two independently firing rules" do
    %{reply: reply} =
      turn!(
        "greg",
        "Tell me if the main room is below 60 and its thermostat is off for twenty minutes."
      )

    assert Rules.list() == []
    assert proposals() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Explains that combined conditions are not supported and asks how to proceed; does not silently split the request into separate rules."
    )
  end

  test "absence means no matching recorded event, even if the current value matches" do
    %{reply: reply} =
      turn!(
        "greg",
        "Tell me if Dobby records no change of the main thermostat setpoint to 70 degrees Fahrenheit for twenty-four hours."
      )

    assert [proposal] = proposals()
    assert proposal.entry["kind"] == "absence"
    assert proposal.entry["attribute"] == "target_temperature_f"
    assert proposal.entry["operator"] == "eq"
    assert proposal.entry["value"] == 70
    assert proposal.entry["event_kind"] == "device_changed"
    assert proposal.entry["action"] == "state_changed"
    assert proposal.entry["duration_seconds"] == 86_400
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Explains the proposed absence in Dobby's recorded changes, without claiming proof that the physical event never happened."
    )

    report("standing absence interpretation", reply)
  end

  test "a conditional command is not invented into an observation rule or a schedule" do
    %{reply: reply} =
      turn!(
        "greg",
        "Whenever the main room drops below 60, automatically set its thermostat to 75."
      )

    assert Rules.list() == []
    assert proposals() == []
    assert Schedules.list_schedules() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Explains that standing rules can notify but cannot automatically change the thermostat on a condition; does not claim that automation was created."
    )

    report("unsupported conditional actuation", reply)
  end

  test "an existing rule is found and paused by name without creating another" do
    assert {:ok, _} =
             Rules.save(%{
               "id" => "cold-room",
               "name" => "Cold room",
               "source" => "Tell me when the main room stays below 60 for twenty minutes",
               "device" => "thermostat:main",
               "kind" => "state",
               "attribute" => "current_temperature_f",
               "operator" => "lt",
               "value" => 60,
               "duration_seconds" => 1200
             })

    Trace.reset()
    %{reply: reply} = turn!("maya", "Pause the Cold room rule.")
    assert "list_rules" in Trace.tool_calls()
    assert [%{id: "cold-room", enabled: false}] = Rules.list()
    assert proposals() == []
    assert Trace.ha_calls() == []
    report("pause standing rule by household name", reply)
  end

  defp proposals do
    Repo.all(from(p in Proposal, where: p.status == "proposed", order_by: p.id))
  end
end
