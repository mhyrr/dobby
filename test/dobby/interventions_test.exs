defmodule Dobby.InterventionsTest do
  @moduledoc """
  Every path that can move this house, and what the thread says about it.

  The rule under all of these (design §10.3) is one sentence: **the thread
  records interventions, the log records everything.** These tests are that
  sentence made checkable from four directions — a card someone tapped, a
  schedule at eight o'clock, a hand on the dial in the hallway, and an endpoint
  going quiet at 3am, which is the one that must stay out of the thread.

  The fifth direction, a tool call the model made, lives in
  `Dobby.Conversation.TurnTest` where the rest of a turn is.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Activity
  alias Dobby.Controls
  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Schedules
  alias Dobby.ThreadEvents

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @endpoint "binary_sensor.kitchen_tv"

  setup do
    ThreadEvents.subscribe()

    seed_house(%{
      @entity => thermostat_entity(current: 68, target: 70),
      @endpoint => %{state: "on", attributes: %{}}
    })

    :ok
  end

  describe "the house coming up" do
    # Every restart pushes the current state of every device. That is the house
    # learning what it has, not something that happened in it, and a thread that
    # said otherwise would announce the boot sequence to the kitchen — and, in
    # the test database, would write rows outside the sandbox that never roll
    # back. Both of those happened; this is what stops them coming back.
    test "is not something that happened in the house" do
      settle!()

      assert system_lines() == []
      assert Activity.recent() == []
    end
  end

  describe "a card someone tapped" do
    test "moves the house and says who did it" do
      assert {:ok, %{temperature_f: 72}} =
               Controls.set_temperature(@thermostat, 72, via: "greg, card")

      assert_receive {:system_line, %Message{role: :system, text: "main thermostat", meta: meta}}
      assert meta["via"] == "greg, card"
      assert meta["word"] == "Set"
      assert meta["state"] == "set"
      assert meta["value"] == "72°"
      assert meta["device"] == @thermostat
    end

    # The setpoint comes back around the physical confirm loop, and the thread
    # must not say it twice — once as "greg, card" and once as though somebody
    # had walked over and turned the dial.
    test "is said once, not twice when Home Assistant echoes it back" do
      {:ok, _result} = Controls.set_temperature(@thermostat, 72, via: "greg, card")

      assert eventually(fn -> agent_state(@thermostat).target_temperature_f == 72.0 end)
      settle!()

      assert [%Message{meta: %{"via" => "greg, card"}}] = system_lines()
    end

    test "a refusal stays on the card and out of the thread" do
      # Above the household maximum of 76 the rig configures.
      assert {:held, reason} = Controls.set_temperature(@thermostat, 85, via: "greg, card")
      assert reason =~ "maximum"

      settle!()

      # Nothing changed, so there was no intervention. The log still has it,
      # because the log has everything.
      assert system_lines() == []
      assert Fake.trace() == []
      assert [entry] = Enum.filter(Activity.recent(), &(&1.kind == "control"))
      assert entry.result["state"] == "held"
    end

    test "reaches the device by the same path a sentence does" do
      {:ok, _result} = Controls.set_temperature(@thermostat, 72, via: "greg, card")

      assert_receive {:ha_call, %HACall{entity_id: @entity, data: %{temperature: 72.0}}}, 2_000
    end

    # Identity personalizes and never permits (§10.4). A browser nobody has
    # named still gets to turn the heat up; the line just says less about who.
    test "still works from a browser nobody has named" do
      assert {:ok, _result} = Controls.set_temperature(@thermostat, 72)
      assert_receive {:system_line, %Message{meta: %{"via" => "card"}}}
    end
  end

  describe "somebody turning the dial in the hallway" do
    test "is an intervention Dobby did not make" do
      Fake.inject_state_changed(@entity, thermostat_entity(current: 68, target: 66))

      assert_receive {:system_line, %Message{text: "main thermostat", meta: meta}}
      assert meta["via"] == "changed at the main thermostat"
      assert meta["value"] == "66°"
    end

    test "the room getting colder is weather, and stays off the thread" do
      Fake.inject_state_changed(@entity, thermostat_entity(current: 64, target: 70))

      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
      settle!()

      assert system_lines() == []

      # The log took it, which is the half of the split that never filters.
      assert [entry] = Enum.filter(Activity.recent(), &(&1.kind == "device_changed"))
      assert entry.device == @thermostat
    end
  end

  describe "an endpoint going quiet at 3am" do
    test "belongs to the log and nowhere else" do
      Fake.inject_state_changed(@endpoint, %{state: "off", attributes: %{}})

      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
      settle!()

      assert system_lines() == []

      assert [entry] = Enum.filter(Activity.recent(), &(&1.device == "wifi:kitchen_tv"))
      assert entry.kind == "device_changed"
      assert entry.result["online"] == false
    end
  end

  describe "a schedule at eight o'clock" do
    test "names itself in the thread" do
      fire!(create!(label: "weeknight heat", args: %{"temperature_f" => 72}))

      assert_receive {:system_line, %Message{text: "main thermostat", meta: meta}}, 2_000
      assert meta["via"] == ~s(schedule "weeknight heat")
      assert meta["word"] == "Set"
      assert meta["value"] == "72°"
    end

    # A schedule the thermostat refused is not an intervention — nothing moved
    # — but a household that finds out at bedtime that the heat never came on
    # is worse served by silence. HELD, quietly, with its reason beside it.
    test "says so quietly when the thermostat refuses it" do
      fire!(create!(label: "far too warm", args: %{"temperature_f" => 85}))

      assert_receive {:system_line, %Message{text: "main thermostat", meta: meta}}, 2_000
      assert meta["word"] == "Held"
      assert meta["state"] == "refused"
      assert meta["reason"] =~ "maximum"
      assert meta["via"] == ~s(schedule "far too warm")
    end

    test "is in the log whatever it did" do
      fire!(create!(label: "weeknight heat", args: %{"temperature_f" => 72}))

      entry =
        eventually(fn ->
          settle!()
          Enum.find(Activity.recent(), &(&1.kind == "schedule_fired"))
        end)

      assert entry.actor == ~s(schedule "weeknight heat")
      assert entry.device == @thermostat
      assert entry.action == "set_temperature"
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp system_lines do
    Enum.filter(Conversation.list_messages(), &(&1.role == :system))
  end

  # The watcher is a process, so "has it finished" is a question with an answer
  # rather than a sleep: a synchronous call queues behind its whole mailbox.
  defp settle!, do: settle_watcher!()

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

  # The signal a tick carries, built by the function `SchedulerAgent.Sync`
  # registers — a test that hand-rolled it would be testing something
  # production never sends.
  defp fire!(schedule) do
    Dobby.SchedulerAgent.id()
    |> Dobby.Jido.whereis()
    |> Jido.AgentServer.cast(Schedules.fire_signal(schedule))
  end
end
