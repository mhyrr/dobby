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
      "Asks the household for a time, or what bedtime means, rather than choosing an hour itself."
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

  # -- the rest of the landscape -------------------------------------------
  #
  # One scenario per thing the model has to know when to do: a zero duration,
  # a window with named days, a refusal it must relay, a reading's unit, a
  # notice to acknowledge rather than a rule to pause, listing, deleting, a
  # "yes" in the same breath, and a device it must ask about.

  test "the moment something happens is a zero-duration state rule" do
    seed_house(%{"lock.front_door" => %{state: "locked", attributes: %{}}})
    %{reply: reply} = turn!("greg", "Tell me the moment the front door unlocks.")

    assert [proposal] = proposals()
    assert proposal.entry["kind"] == "state"
    assert proposal.entry["device"] == "lock:front"
    assert proposal.entry["attribute"] == "lock_state"
    assert proposal.entry["operator"] == "eq"
    assert proposal.entry["value"] == "unlocked"
    assert proposal.entry["duration_seconds"] == 0
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Shows the proposed condition and asks for agreement; does not claim it is already watching."
    )

    report("standing rule zero duration", reply)
  end

  test "weeknights between two clock times become a window with named days" do
    seed_house(%{"cover.garage_door" => %{state: "closed", attributes: %{current_position: 0}}})

    %{reply: reply} =
      turn!(
        "greg",
        "On weeknights between 10pm and 6am, tell me if the garage door stays open for ten minutes."
      )

    assert [proposal] = proposals()
    assert proposal.entry["device"] == "cover:garage"
    assert proposal.entry["attribute"] == "cover_state"
    assert proposal.entry["value"] == "open"
    assert proposal.entry["duration_seconds"] == 600
    assert %{"start" => "22:00", "end" => "06:00", "days" => days} = proposal.entry["window"]

    assert days in [[1, 2, 3, 4, 5], [1, 2, 3, 4, 7]],
           "weeknights are five nights: #{inspect(days)}"

    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Describes the rule with its overnight window and the nights it applies to, and asks for agreement."
    )

    report("standing rule weeknight window", reply)
  end

  test "a duration the window cannot hold is relayed as a refusal, not quietly shortened" do
    seed_house(%{"cover.garage_door" => %{state: "closed", attributes: %{current_position: 0}}})

    %{reply: reply} =
      turn!(
        "greg",
        "Between 10pm and 6am on weekdays, tell me if the garage door stays open for nine hours."
      )

    assert proposals() == []
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Explains that nine hours cannot fit inside the eight-hour window; does not say a rule was proposed or saved."
    )

    report("standing rule duration exceeds window", reply)
  end

  test "an environmental reading carries the unit the device reports" do
    seed_house(%{
      "sensor.office_temperature" => %{
        state: "72.4",
        attributes: %{device_class: "temperature", unit_of_measurement: "°F"}
      },
      "sensor.office_humidity" => %{
        state: "41",
        attributes: %{device_class: "humidity", unit_of_measurement: "%"}
      }
    })

    %{reply: reply} =
      turn!("greg", "Tell me if the office humidity stays above 60 percent for an hour.")

    assert [proposal] = proposals()
    assert proposal.entry["device"] == "monitor:office"
    assert proposal.entry["attribute"] == "humidity"
    assert proposal.entry["operator"] == "gt"
    assert proposal.entry["value"] == 60
    assert proposal.entry["unit"] == "%"
    assert proposal.entry["duration_seconds"] == 3600
    assert Rules.list() == []
    assert Trace.ha_calls() == []
    report("standing rule environmental unit", reply)
  end

  test "a standing notice is acknowledged, not paused or deleted" do
    assert {:ok, _} = Rules.save(cold_room(%{"value" => 70, "duration_seconds" => 0}))
    :ok = Dobby.Rules.Watcher.check()
    assert [%{acknowledged: false}] = Rules.notices()
    Trace.reset()

    %{reply: reply} =
      turn!("greg", "I know about the cold room, you can stop showing me that notice.")

    assert "acknowledge_rule" in Trace.tool_calls()
    assert Rules.notices() == []
    assert [%{id: "cold-room", enabled: true}] = Rules.list()
    assert Trace.ha_calls() == []
    report("acknowledge standing notice", reply)
  end

  test "what is being watched is answered from the list, with nothing invented" do
    assert {:ok, _} = Rules.save(cold_room())

    assert {:ok, _} =
             Rules.save(%{
               "id" => "garage-open",
               "name" => "Garage left open",
               "device" => "cover:garage",
               "kind" => "state",
               "attribute" => "cover_state",
               "operator" => "eq",
               "value" => "open",
               "duration_seconds" => 600
             })

    Trace.reset()
    %{reply: reply} = turn!("maya", "What are you keeping an eye on for us?")
    assert "list_rules" in Trace.tool_calls()
    assert proposals() == []
    assert length(Rules.list()) == 2
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Names both the cold room rule and the garage door rule, and does not mention any other rule."
    )

    report("list standing rules", reply)
  end

  test "a rule is deleted by its household name" do
    assert {:ok, _} = Rules.save(cold_room())
    Trace.reset()
    %{reply: reply} = turn!("greg", "Delete the cold room rule, I don't need it anymore.")
    assert "delete_rule" in Trace.tool_calls()
    assert Rules.list() == []
    assert proposals() == []
    assert Trace.ha_calls() == []
    report("delete standing rule by name", reply)
  end

  test "a yes in the same breath as the request is still only a proposal" do
    %{reply: reply} =
      turn!(
        "greg",
        "Tell me if the main thermostat stays below 60 for twenty minutes. Yes, I'm sure, go ahead and save it."
      )

    assert [_proposal] = proposals()
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Shows the proposed rule and asks for agreement; does not claim the rule is saved or already watching."
    )

    report("same-breath agreement is still a proposal", reply)
  end

  test "a door in a house with two locks is a question, not a rule for either" do
    seed_house(%{
      "lock.front_door" => %{state: "locked", attributes: %{}},
      "lock.side_door" => %{state: "unlocked", attributes: %{}}
    })

    %{reply: reply} = turn!("greg", "Tell me if the door stays unlocked for an hour.")
    assert proposals() == []
    assert Rules.list() == []
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Asks which door is meant and does not propose a rule for any door."
    )

    report("ambiguous device for a rule", reply)
  end

  defp cold_room(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "cold-room",
        "name" => "Cold room",
        "source" => "Tell me when the main room stays below 60 for twenty minutes",
        "device" => "thermostat:main",
        "kind" => "state",
        "attribute" => "current_temperature_f",
        "operator" => "lt",
        "value" => 60,
        "duration_seconds" => 1200
      },
      overrides
    )
  end

  defp proposals do
    Repo.all(from(p in Proposal, where: p.status == "proposed", order_by: p.id))
  end
end
