defmodule Dobby.Eval.ScheduleEvalTest do
  @moduledoc """
  Schedule authoring against a real model.

      DOBBY_EVAL=1 mix test --only eval

  Design §6.2 calls authoring the place the language work concentrates, and
  this is why: "every weekday at 7am" has to become a cron expression once,
  correctly, because nothing ever re-reads the sentence. The replay tier cannot
  ask that question at all — its scripts *are* the answer.

  ## What is asserted, and what is only printed

  Cron strings are not compared. `"0 7 * * 1-5"` and `"0 7 * * MON-FRI"` are
  the same schedule, and pinning either would fail a model for spelling. What
  is asserted is what the expression *means*, by asking
  `Dobby.Schedules.Cron.next_fire/3` from a known moment — which is the same
  simulated clock the replay tier uses, pointed at the model's output instead
  of ours.

  One invariant holds in every scenario here, and it is the one worth stating:
  **authoring a schedule never actuates the house.** A model that answers "I
  always want it at 70 at eight" by setting the thermostat to 70 right now has
  misunderstood the entire feature.
  """

  use Dobby.RigCase, async: false

  import Dobby.Eval

  alias Dobby.Schedules

  @moduletag :eval
  @moduletag timeout: 180_000

  @climate "climate.main_floor"

  # A Sunday, so "weekdays" has somewhere to land that is not today.
  @sunday ~U[2026-08-16 12:00:00Z]

  setup do
    seed_house(%{@climate => thermostat_entity(current: 66, target: 68)})
    Trace.reset()
    :ok
  end

  test "an unambiguous recurring request becomes a schedule that means what was asked" do
    reply = say!("greg", "Dobby, every weekday at 7am set the thermostat to 68")

    assert Trace.ha_calls() == [],
           "authoring a schedule changed the house now: #{inspect(Trace.ha_calls())}"

    assert [schedule] = Schedules.list_schedules()
    assert schedule.target == "thermostat:main"
    assert schedule.action == "set_temperature"
    assert schedule.args == %{"temperature_f" => 68.0}
    assert schedule.created_by == "greg"

    # The meaning, not the spelling: from Sunday noon, the next firing is
    # Monday at seven in the morning, local.
    assert {:ok, next} = Schedules.Cron.next_fire(schedule.cron, schedule.timezone, @sunday)
    assert Date.day_of_week(DateTime.to_date(next)) == 1
    assert next.hour == 7 and next.minute == 0

    # And it is actually armed, not merely stored.
    assert Dobby.SchedulerAgent.unregistered() == []

    report("schedule authoring — cron: #{schedule.cron}", reply)
  end

  test "\"by 8pm\" is treated as the ambiguity it is, and nothing is actuated either way" do
    # Design §6.2's example. "At 70 by 8pm" can mean "set it to 70 at eight" or
    # "have the room at 70 when eight arrives", and only one of those is
    # something this house can do. The doctrine says ask.
    #
    # Both outcomes are printed for a human to judge. What is asserted is that
    # neither of them touches the thermostat tonight, and that if a schedule
    # was written it fires on weekday evenings rather than at some hour the
    # model invented.
    reply = say!("greg", "Dobby, I always want the thermostat at 70 by 8pm on weekdays")

    assert Trace.ha_calls() == [],
           "a request about eight o'clock changed the house now: #{inspect(Trace.ha_calls())}"

    case Schedules.list_schedules() do
      [] ->
        report("by-8pm ambiguity — clarified", reply)

      [schedule] ->
        assert {:ok, next} = Schedules.Cron.next_fire(schedule.cron, schedule.timezone, @sunday)
        assert Date.day_of_week(DateTime.to_date(next)) == 1
        assert next.hour == 20

        report("by-8pm ambiguity — scheduled #{schedule.cron}", reply)
    end
  end

  test "a schedule aimed at something the house cannot schedule is not invented into one" do
    reply = say!("greg", "Dobby, restart the office printer every night at 3am")

    # There is no schedulable action on a Wi-Fi endpoint, so the only failure
    # modes available are a confused thermostat schedule or a confident lie.
    assert Trace.ha_calls() == []

    assert Enum.all?(Schedules.list_schedules(), &(&1.target != "wifi:office_printer")),
           "invented a schedule for a device that publishes no schedulable actions"

    report("unschedulable device", reply)
  end

  test "a schedule the model never authored can still be found and paused by name" do
    # The row is written through the production path rather than by asking the
    # model to write it first. Two reasons, and the second one is why this
    # scenario changed shape after a run.
    #
    # It is a stronger test: the model has never seen this id, so it cannot
    # recall it from the conversation and has to go and look. That is the
    # round trip the admin dashboard creates every day — someone adds a
    # schedule on the web, someone else asks Dobby to pause it.
    #
    # And it isolates what is being measured. When authoring was turn one, a
    # run where the model chose to clarify instead failed this scenario for a
    # reason that has nothing to do with pausing. Authoring is measured above;
    # here it is a fixture, and a fixture should not be a coin flip.
    {:ok, created} =
      Schedules.create_schedule(%{
        label: "morning warmup",
        cron: "0 7 * * 1-5",
        timezone: Dobby.Home.manifest().timezone,
        target: "thermostat:main",
        action: "set_temperature",
        args: %{"temperature_f" => 68},
        created_by: "greg",
        created_via: :admin
      })

    Trace.reset()

    reply = say!("maya", "Dobby, pause the morning warmup schedule")

    assert {:ok, schedule} = Schedules.fetch(created.id)
    refute schedule.enabled, "asked to pause a schedule and it is still enabled"

    assert Trace.ha_calls() == []
    refute job_running?(schedule), "paused schedule still has a timer"

    # It had to look the schedule up — the id was never in the conversation.
    assert "list_schedules" in Trace.tool_calls()

    report("pause by name", reply)
  end

  defp job_running?(schedule) do
    pid = Dobby.Jido.whereis(Dobby.SchedulerAgent.id())
    {:ok, server_state} = Jido.AgentServer.state(pid)
    Map.has_key?(server_state.cron_jobs, Schedules.job_id(schedule))
  end
end
