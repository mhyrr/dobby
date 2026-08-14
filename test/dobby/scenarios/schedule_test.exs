defmodule Dobby.Scenarios.ScheduleTest do
  @moduledoc """
  Scenario 9: "I always want the thermostat at 70 by 8pm on weekdays."

  Two halves that must not touch. Authoring goes through the model and changes
  nothing in the house. Firing goes nowhere near a model and changes the house.
  The assertion that ties them together is a zero — `Trace.llm_calls() == []`
  around a firing — and it is the one this whole step exists to make.

  ## What "simulated clock" means here, exactly

  Jido's cron jobs read `DateTime.now/2` and arm `Process.send_after`. There is
  no clock to inject, so this file simulates time in the two honest ways
  available rather than pretending to one that is not.

  *Schedule semantics* — does `0 20 * * 1-5` mean Monday evening when asked on
  Saturday, and what does it do on a spring-forward morning — is a pure
  question answered against a supplied `from`. That lives in
  `Dobby.SchedulesTest`.

  *Firing* is driven by casting the signal the timer casts, built by
  `Dobby.Schedules.fire_signal/1` — the same function `SchedulerAgent.Sync`
  registers. A test that hand-rolled that signal would be testing something
  production never sends.

  And because "the same signal" is only worth as much as the thing that carries
  it, one test lets the real timer do the work end to end. It uses a
  seconds-resolution cron so that costs a second rather than a minute — which
  is the only reason six-field expressions are accepted at all.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.{DobbyAgent, Schedules, SchedulerAgent, Utterance}

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
    Trace.reset()
    :ok
  end

  describe "authoring" do
    test "a spoken schedule becomes a row, and the house does not move" do
      utterance = Utterance.new("greg", "I want the thermostat at 70 at 8pm on weekdays")

      script =
        expect_react do
          user(Utterance.to_message(utterance))

          call("create_schedule", %{
            "label" => "weeknight heat",
            "cron" => "0 20 * * 1-5",
            "device" => @thermostat,
            "action" => "set_temperature",
            "args" => %{"temperature_f" => 70}
          })

          answer("Set — weeknight heat, 70° at 8pm Monday to Friday.")
        end

      assert {:ok, reply} = DobbyAgent.say(utterance, react_opts(script))
      assert reply =~ "70"

      assert [schedule] = Schedules.list_schedules()
      assert schedule.label == "weeknight heat"
      assert schedule.cron == "0 20 * * 1-5"
      assert schedule.target == @thermostat
      assert schedule.args == %{"temperature_f" => 70.0}

      # Attribution came from the request context, not from anything the model
      # was asked to repeat back (§6.4).
      assert schedule.created_by == "greg"
      assert schedule.created_via == :conversation

      # The whole point of a schedule: nothing happens now.
      assert Fake.trace() == []
      assert Trace.ha_calls() == []

      # And the timer exists, which is the difference between a schedule and a
      # row that looks like one.
      assert SchedulerAgent.unregistered() == []
      assert job_running?(schedule)
    end

    test "a schedule the house cannot keep is refused to the model as an observation" do
      utterance = Utterance.new("greg", "keep the kitchen thermostat at 70 overnight")

      script =
        expect_react do
          user(Utterance.to_message(utterance))

          call("create_schedule", %{
            "label" => "kitchen overnight",
            "cron" => "0 22 * * *",
            "device" => "thermostat:kitchen",
            "action" => "set_temperature",
            "args" => %{"temperature_f" => 70}
          })

          answer("There's no kitchen thermostat here — only the main one.")
        end

      assert {:ok, _reply} = DobbyAgent.say(utterance, react_opts(script))

      # The refusal happened in our code, not in the model's manners, and the
      # model had to account for it in its reply.
      assert Schedules.list_schedules() == []
      assert Trace.tool_calls() == ["create_schedule"]
      assert Trace.ha_calls() == []
    end
  end

  describe "firing" do
    test "a firing actuates the house and contains no model call at all" do
      schedule = create!(label: "weeknight heat", args: %{"temperature_f" => 70})
      Trace.reset()

      fire!(schedule)

      # `assert_receive` rather than a trace ordering: telemetry cannot order
      # events across sources (§12), and a message is a real happens-before.
      assert_receive {:ha_call, %HACall{entity_id: @entity, data: %{temperature: 70.0}}}, 2_000

      # The assertion this step exists to make.
      assert Trace.llm_calls() == []
      assert Trace.tool_calls() == []

      assert Trace.firings() == [{"weeknight heat", :accepted}]

      # And the setpoint came back around the physical confirm loop, exactly as
      # it does when a person asks.
      assert eventually(fn -> agent_state(@thermostat).target_temperature_f == 70.0 end)
    end

    test "the timer itself fires — not merely the action behind it" do
      # Everything above casts the signal by hand. This one waits for Jido's
      # cron job to cast it, which is the only test here that would notice if
      # the `Cron` directive stopped registering.
      _schedule = create!(label: "every second", cron: "*/1 * * * * *")
      Trace.reset()

      assert_receive {:ha_call, %HACall{entity_id: @entity, data: %{temperature: 70.0}}}, 5_000
      assert Trace.llm_calls() == []
    end

    test "household policy still applies at eight o'clock, and the refusal is announced" do
      # The setpoint the authoring layer deliberately does not check, because
      # the range comes from capabilities discovered from the hardware. Here is
      # where it gets checked, by the device agent, exactly as it would if a
      # person had asked out loud.
      schedule = create!(label: "far too warm", args: %{"temperature_f" => 85})
      Trace.reset()

      fire!(schedule)

      assert_receive %Jido.Signal{
                       type: "dobby.schedule.fired",
                       data: %{outcome: {:rejected, reason}}
                     },
                     2_000

      assert reason =~ "maximum"

      # Refused means refused: nothing reached Home Assistant.
      assert Fake.trace() == []
      assert Trace.llm_calls() == []
    end

    test "a paused schedule that somehow ticks does nothing" do
      schedule = create!(label: "weeknight heat")
      {:ok, paused} = Schedules.set_enabled(schedule.id, false)
      Trace.reset()

      fire!(paused)

      assert_receive %Jido.Signal{type: "dobby.schedule.fired", data: %{outcome: :paused}}, 2_000
      assert Fake.trace() == []
    end

    test "a deleted schedule that somehow ticks does not resurrect itself" do
      schedule = create!(label: "weeknight heat")
      {:ok, _deleted} = Schedules.delete_schedule(schedule.id)
      Trace.reset()

      # The timer is already cancelled; this is the race where a tick was
      # in flight when the row went away.
      fire!(schedule)

      refute_receive {:ha_call, _call}, 300
      assert Schedules.list_schedules() == []
    end
  end

  describe "the timer follows the rows" do
    test "pausing cancels the timer and resuming brings it back" do
      schedule = create!(label: "weeknight heat")
      assert job_running?(schedule)

      {:ok, paused} = Schedules.set_enabled(schedule.id, false)
      refute job_running?(paused)
      assert SchedulerAgent.unregistered() == []

      {:ok, resumed} = Schedules.set_enabled(schedule.id, true)
      assert job_running?(resumed)
    end

    test "deleting cancels the timer" do
      schedule = create!(label: "weeknight heat")
      assert job_running?(schedule)

      {:ok, _deleted} = Schedules.delete_schedule(schedule.id)
      refute job_running?(schedule)
    end

    test "a restart rebuilds every timer from the rows, and only from the rows" do
      # Nothing about a schedule lives in a process. This is the property that
      # makes "the rows are the truth" true rather than aspirational.
      first = create!(label: "weeknight heat")
      second = create!(label: "morning warmup", cron: "30 6 * * *")
      {:ok, _paused} = Schedules.set_enabled(second.id, false)

      restart_house!()

      assert job_running?(first)
      refute job_running?(second)
      assert SchedulerAgent.unregistered() == []
    end

    test "a schedule whose device left the manifest gets no timer and says why" do
      schedule = create!(label: "weeknight heat")

      # What editing the manifest and restarting does in production (§2.4).
      boot_house!([thermostat_device("thermostat:spare", "spare thermostat")])

      refute job_running?(schedule)
      assert Schedules.describe(schedule).status =~ "unknown device"

      # It is blocked, not missing: `unregistered/0` is for timers that should
      # exist and do not, and this one should not.
      assert SchedulerAgent.unregistered() == []
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Through the production write path, so a scenario cannot arrange a schedule
  # the authoring layer would have refused.
  defp create!(overrides) do
    attrs =
      %{
        label: "weeknight heat",
        cron: "0 20 * * 1-5",
        timezone: Dobby.Home.manifest().timezone,
        target: @thermostat,
        action: "set_temperature",
        args: %{"temperature_f" => 70},
        created_by: "greg",
        created_via: :conversation
      }
      |> Map.merge(Map.new(overrides))

    {:ok, schedule} = Schedules.create_schedule(attrs)
    schedule
  end

  # The clock, simulated: the signal a tick carries, cast the way a tick casts
  # it. Built by production code — see this module's notes.
  defp fire!(schedule) do
    Dobby.SchedulerAgent.id()
    |> Dobby.Jido.whereis()
    |> Jido.AgentServer.cast(Schedules.fire_signal(schedule))
  end

  defp job_running?(schedule) do
    pid = Dobby.Jido.whereis(Dobby.SchedulerAgent.id())
    {:ok, server_state} = Jido.AgentServer.state(pid)
    Map.has_key?(server_state.cron_jobs, Schedules.job_id(schedule))
  end

  defp restart_house! do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
  end
end
