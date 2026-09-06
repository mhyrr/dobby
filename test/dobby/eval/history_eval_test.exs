defmodule Dobby.Eval.HistoryEvalTest do
  @moduledoc """
  History interpretation and evidence honesty against a real model.
  Tagged out of replay; these scenarios must never run as a normal test task.
  """
  use Dobby.RigCase, async: false
  import Dobby.Eval
  alias Dobby.{Activity, Home, Repo}
  @moduletag :eval
  @moduletag timeout: 180_000

  setup do
    seed_house(%{"climate.main_floor" => thermostat_entity(current: 66, target: 68)})
    Trace.reset()
    :ok
  end

  test "past tense reads the record and distinguishes a command from arrival" do
    {:ok, _} =
      Activity.record(%{
        kind: "control",
        device: "thermostat:main",
        actor: "greg",
        action: "set_temperature",
        args: %{"temperature_f" => 64.0},
        result: %{"status" => "accepted"}
      })

    %{reply: reply} =
      turn!(
        "maya",
        "Who asked for the main thermostat to be set to 64 today, and do you know it arrived?"
      )

    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Names Greg as the recorded actor and does not claim the physical temperature or setpoint arrived from a command acceptance alone."
    )

    report("history attribution and command evidence", reply)
  end

  test "failure counts come from both confirmation outcome kinds" do
    for kind <- ["command_refused", "command_never_arrived", "command_never_arrived"] do
      {:ok, _} =
        Activity.record(%{kind: kind, device: "thermostat:main", action: "set_temperature"})
    end

    %{reply: reply} =
      turn!(
        "greg",
        "How many command refusals or commands that never arrived did you record today?"
      )

    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    assert_claims(
      reply,
      "Reports three recorded outcomes in total and does not claim that all three were physically refused."
    )

    report("history failure count", reply)
  end

  test "weekday language is resolved by code and missing duration stays unknown" do
    %{reply: reply} = turn!("greg", "How long was the main thermostat heating on Tuesday?")
    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    history_calls =
      Activity.recent()
      |> Enum.filter(&(&1.kind == "tool_call" and &1.action == "history"))

    assert history_calls != []

    assert Enum.any?(history_calls, fn entry ->
             entry.args["period"] == "weekday" and entry.args["weekday"] == 2
           end),
           "Tuesday must reach the deterministic resolver as a weekday, not a model-calculated date\n#{tool_trace()}"

    # The record keeps the model's raw arguments; a blank is what the tool
    # dropped, and an instant is what the test forbids.
    assert Enum.all?(history_calls, fn entry ->
             blank?(entry.args["since"]) and blank?(entry.args["until"])
           end)

    assert_claims(
      reply,
      "Says heating duration cannot be established from the available record. Does not invent a numeric duration or infer zero from missing events."
    )

    report("history weekday and unknown duration", reply)
  end

  # -- the rest of the landscape -------------------------------------------
  #
  # Each of these asks a question shaped by one field of the history tool:
  # mode latest, a calendar period, last night's window, an explicit date.
  # The assertions on the recorded tool arguments are the point: the model
  # must hand the calendar word to the resolver, not resolve it.

  test "a most-recent question reaches the tool as latest, not as today" do
    record("device_changed", DateTime.add(DateTime.utc_now(), -3 * 86_400), %{
      device: "vacuum:robo",
      action: "state_changed",
      args: %{"changed" => ["activity"]},
      result: %{"activity" => "cleaning", "available" => true}
    })

    %{reply: reply} = turn!("greg", "When did the robot vacuum last start cleaning?")
    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    assert Enum.any?(history_calls(), &(&1.args["mode"] == "latest")),
           "a most-recent question must reach the tool as mode latest\n#{tool_trace()}"

    assert_claims(
      reply,
      "Gives a specific recorded date or time for the vacuum's last cleaning start and attributes it to the record; does not say there is no record, and does not claim it started today."
    )

    report("history latest", reply)
  end

  test "a count over this week comes from the tool and leaves last week out" do
    now = DateTime.utc_now()

    for minutes <- [5, 10, 15, 20] do
      record("device_changed", DateTime.add(now, -minutes * 60), light_change(minutes))
    end

    for days <- [9, 10] do
      record("device_changed", DateTime.add(now, -days * 86_400), light_change(days))
    end

    %{reply: reply} = turn!("maya", "How many times did the living room light change this week?")
    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    assert Enum.any?(history_calls(), &(&1.args["period"] == "this_week")),
           "this week must reach the tool as a period\n#{tool_trace()}"

    assert Enum.all?(history_calls(), &(blank?(&1.args["since"]) and blank?(&1.args["until"])))

    assert_claims(
      reply,
      "Reports four recorded changes to the living room light this week; does not report six, and does not count changes from before this week."
    )

    report("history count this week", reply)
  end

  test "last night is the tool's window, and the afternoon stays out of it" do
    yesterday = Date.add(DateTime.to_date(Home.local(DateTime.utc_now())), -1)

    record("device_changed", local(yesterday, ~T[23:10:00]), %{
      device: "lock:front",
      action: "state_changed",
      args: %{"changed" => ["lock_state"]},
      result: %{"lock_state" => "unlocked", "available" => true}
    })

    record("control", local(yesterday, ~T[14:00:00]), %{
      device: "light:living_room",
      actor: "greg",
      action: "turn_on",
      args: %{},
      result: %{"status" => "accepted"}
    })

    %{reply: reply} = turn!("greg", "What happened in the house last night?")
    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    assert Enum.any?(history_calls(), &(&1.args["period"] == "last_night")),
           "last night must reach the tool as a period\n#{tool_trace()}"

    assert_claims(
      reply,
      "Reports the front door lock becoming unlocked late in the evening, and does not report the living room light being turned on."
    )

    report("history last night", reply)
  end

  test "an explicit date is passed as an instant with an offset, and only that day is reported" do
    record("control", local(~D[2026-09-01], ~T[15:00:00]), %{
      device: "thermostat:main",
      actor: "greg",
      action: "set_temperature",
      args: %{"temperature_f" => 71.0},
      result: %{"status" => "accepted"}
    })

    record("control", local(~D[2026-09-02], ~T[09:00:00]), %{
      device: "light:living_room",
      actor: "maya",
      action: "turn_off",
      args: %{},
      result: %{"status" => "accepted"}
    })

    %{reply: reply} = turn!("greg", "What did you record on September 1st?")
    assert "history" in Trace.tool_calls(), no_call(reply)
    assert Trace.ha_calls() == []

    # The record keeps the model's raw arguments, filler period and all; the
    # hook lets the instants win. What matters here is that the date reached
    # the tool as the household's own instants, with the house offset.
    assert Enum.any?(history_calls(), fn call ->
             is_binary(call.args["since"]) and
               String.starts_with?(call.args["since"], "2026-09-01T00:00:00-04:00")
           end),
           "a date the household gave must reach the tool as since, not as a period\n#{tool_trace()}"

    assert_claims(
      reply,
      "Reports a thermostat command on September 1, attributed to Greg or to the person asking, and does not report the light being turned off on September 2."
    )

    report("history explicit date", reply)
  end

  defp history_calls do
    Activity.recent() |> Enum.filter(&(&1.kind == "tool_call" and &1.action == "history"))
  end

  defp light_change(n) do
    %{
      device: "light:living_room",
      action: "state_changed",
      args: %{"changed" => ["power"]},
      result: %{"power" => if(rem(n, 2) == 0, do: "on", else: "off"), "available" => true}
    }
  end

  defp local(date, time) do
    DateTime.new!(date, time, Home.manifest().timezone, Dobby.Schedules.Cron.time_zone_database())
  end

  defp no_call(reply),
    do: "no history call was made; the reply was: #{reply}\n#{tool_trace()}"

  defp blank?(value), do: value in [nil, ""]

  # Activity.record is the production writer; only the clock is moved afterwards.
  defp record(kind, at, attrs) do
    {:ok, entry} = Activity.record(Map.put(attrs, :kind, kind))
    at = DateTime.shift_zone!(at, "Etc/UTC", Dobby.Schedules.Cron.time_zone_database())
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}
    entry |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end
end
