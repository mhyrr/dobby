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
  alias Dobby.Home
  alias Dobby.Schedules
  alias Dobby.ThreadEvents
  alias DobbyWeb.Flap

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

  describe "a person at the door" do
    # The ring rides the event timestamp: `last_event` stays "ring" between
    # two rings, so only `last_event_at` moves per press. The first report
    # after boot is the house learning the bell exists, and stays silent.
    test "a ring is somebody's, and the thread says so" do
      seed_house(%{
        "event.front_door" => %{
          state: "2026-08-23T12:00:00+00:00",
          attributes: %{event_type: "ring", device_class: "doorbell"}
        }
      })

      settle!()
      assert system_lines() == []

      Fake.inject_state_changed("event.front_door", %{
        state: "2026-08-23T18:30:00+00:00",
        attributes: %{event_type: "ring", device_class: "doorbell"}
      })

      assert_receive {:system_line, %Message{text: "front doorbell", meta: meta}}, 2_000
      assert meta["value"] == "Ring"
      assert meta["via"] == "changed at the front doorbell"
    end
  end

  describe "a hand on the deadbolt" do
    # The echo of Dobby's secure command is one-shot: consumed when the lock
    # reports locked. Without that, the standing accepted command would make
    # every later hand-lock read as Dobby's echo, forever — the thread must
    # list every state change of a lock.
    test "re-locking after Dobby once secured is still somebody's hand" do
      seed_house(%{"lock.front_door" => %{state: "unlocked", attributes: %{}}})

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert eventually(fn -> agent_state("lock:front").lock_state == :locked end)
      settle!()

      # The echo of Dobby's own command writes no line; the tool's caller
      # already announced it.
      assert system_lines() == []

      Fake.inject_state_changed("lock.front_door", %{state: "unlocked", attributes: %{}})

      assert_receive {:system_line,
                      %Message{text: "front door lock", meta: %{"value" => "Unlocked"}}},
                     2_000

      Fake.inject_state_changed("lock.front_door", %{state: "locked", attributes: %{}})

      assert_receive {:system_line,
                      %Message{text: "front door lock", meta: %{"value" => "Locked"}}},
                     2_000
    end

    test "the garage door's echo is one-shot the same way" do
      seed_house(%{
        "cover.garage_door" => %{state: "open", attributes: %{current_position: 100}}
      })

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.AccessCoverClose, %{device: "cover:garage"})

      assert eventually(fn -> agent_state("cover:garage").cover_state == :closed end)
      settle!()
      assert system_lines() == []

      Fake.inject_state_changed("cover.garage_door", %{
        state: "open",
        attributes: %{current_position: 100}
      })

      assert_receive {:system_line, %Message{text: "garage door", meta: %{"value" => "Open"}}},
                     2_000

      Fake.inject_state_changed("cover.garage_door", %{
        state: "closed",
        attributes: %{current_position: 0}
      })

      assert_receive {:system_line, %Message{text: "garage door", meta: %{"value" => "Closed"}}},
                     2_000
    end
  end

  describe "Home Assistant answering a command" do
    test "a refusal writes HELD with the reason" do
      seed_unlocked_lock!()
      Fake.fail_next("lock.front_door", :unavailable)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:system_line, %Message{text: "front door lock", meta: meta}}, 2_000
      assert meta["word"] == "Held"
      assert meta["state"] == "refused"
      assert meta["reason"] =~ "unavailable"
      assert meta["via"] == "Home Assistant"

      entry =
        eventually(fn ->
          settle!()
          Enum.find(Activity.recent(), &(&1.kind == "command_refused"))
        end)

      assert entry.device == "lock:front"
      assert entry.action == "lock.secure"
    end

    test "a missing echo writes NOT KNOWN once and puts it on the board" do
      seed_unlocked_lock!()
      Fake.silence_next("lock.front_door")

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:system_line, %Message{text: "front door lock", meta: meta}}, 2_000
      assert meta["word"] == "Not known"
      assert meta["state"] == "silent"
      assert meta["reason"] =~ "no answer since"

      assert_receive %Jido.Signal{
                       type: "dobby.device.command_status_changed",
                       data: %{device: "lock:front", status: :not_known}
                     },
                     2_000

      settle!()
      snapshot = Home.snapshots()["lock:front"]
      assert snapshot.command_status == :not_known
      assert Flap.read(snapshot).word == "Not known"

      assert Enum.count(system_lines(), &(&1.meta["word"] == "Not known")) == 1
    end

    # The expectation carries the device's own reading, taken in the device
    # agent's process before the call went out. Asking the agent for it here
    # would mean asking a process that is, at that exact moment, blocked
    # inside Home Assistant.
    test "a command the device has already answered never becomes an expectation" do
      seed_house(%{"lock.front_door" => %{state: "locked", attributes: %{}}})
      settle!()

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000
      settle!()

      assert expectations_for("lock:front") == []
      assert unknown_for("lock:front") == []
      assert system_lines() == []
    end

    test "an echo inside the deadline cancels the expectation with nothing said" do
      seed_unlocked_lock!()
      Fake.silence_next("lock.front_door")

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000
      settle!()

      assert [expectation] = expectations_for("lock:front")
      assert is_reference(expectation.timer)

      Fake.inject_state_changed("lock.front_door", %{state: "locked", attributes: %{}})
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
      settle!()

      assert expectations_for("lock:front") == []
      assert unknown_for("lock:front") == []
      assert Enum.filter(system_lines(), &(&1.meta["word"] == "Not known")) == []
    end

    # Three silent commands to one device are one fact about that device.
    test "a second silence on the same device is a log row, not a second line" do
      seed_unlocked_lock!()
      silent_secure!()
      silent_secure!()

      assert_receive %Jido.Signal{
                       type: "dobby.device.command_status_changed",
                       data: %{device: "lock:front", status: :not_known}
                     },
                     2_000

      refute_receive %Jido.Signal{
                       type: "dobby.device.command_status_changed",
                       data: %{device: "lock:front"}
                     },
                     500

      settle!()

      assert Enum.count(system_lines(), &(&1.meta["word"] == "Not known")) == 1

      assert Enum.count(
               Activity.recent(),
               &(&1.kind == "command_never_arrived" and &1.device == "lock:front")
             ) == 2
    end

    # The defect this shape exists to prevent: the executor runs *in* the
    # device agent's process and then blocks it for the length of the call, so
    # a witness that asked the agent what it reads would be waiting on a
    # process it had just stopped — and would take every other expectation in
    # flight down with it when the wait ran out.
    test "keeps watching while a device agent is blocked inside Home Assistant" do
      seed_unlocked_lock!()
      watcher = Process.whereis(Dobby.Interventions.Watcher)
      Fake.stall_next("lock.front_door", 600)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000

      # The lock's agent will not answer anything for the next half second.
      # The witness answers at once, and is already holding the expectation.
      assert :ok = GenServer.call(Dobby.Interventions.Watcher, :settle, 250)
      assert [%{device: "lock:front"}] = expectations_for("lock:front")
      assert Process.whereis(Dobby.Interventions.Watcher) == watcher

      # And the slow answer, when it lands, still resolves the expectation.
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
      settle!()

      assert expectations_for("lock:front") == []
      assert Enum.filter(system_lines(), &(&1.meta["word"] == "Not known")) == []
      assert Process.whereis(Dobby.Interventions.Watcher) == watcher
    end

    test "a late echo clears NOT KNOWN without another thread line" do
      seed_unlocked_lock!()
      Fake.silence_next("lock.front_door")

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive %Jido.Signal{
                       type: "dobby.device.command_status_changed",
                       data: %{device: "lock:front", status: :not_known}
                     },
                     2_000

      Fake.inject_state_changed("lock.front_door", %{state: "locked", attributes: %{}})

      assert_receive %Jido.Signal{
                       type: "dobby.device.command_status_changed",
                       data: %{device: "lock:front", status: :clear}
                     },
                     2_000

      settle!()
      refute Map.has_key?(Home.snapshots()["lock:front"], :command_status)
      assert Enum.count(system_lines(), &(&1.meta["word"] == "Not known")) == 1
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp system_lines do
    Enum.filter(Conversation.list_messages(), &(&1.role == :system))
  end

  # The watcher is a process, so "has it finished" is a question with an answer
  # rather than a sleep: a synchronous call queues behind its whole mailbox.
  defp settle!, do: settle_watcher!()

  defp seed_unlocked_lock! do
    seed_house(%{"lock.front_door" => %{state: "unlocked", attributes: %{}}})
    settle!()
  end

  # The witness is an application process and outlives any one scenario, so
  # these read the slice of its state that belongs to this device rather than
  # the whole of it.
  defp expectations_for(device), do: tracked(:expectations, device)
  defp unknown_for(device), do: tracked(:unknown, device)

  defp tracked(key, device) do
    Dobby.Interventions.Watcher
    |> :sys.get_state()
    |> Map.fetch!(key)
    |> Map.values()
    |> Enum.filter(&(&1.device == device))
  end

  # One accepted command Home Assistant never answers. The silence is armed per
  # call, so two of these are two separate unanswered commands.
  defp silent_secure! do
    Fake.silence_next("lock.front_door")

    assert {:ok, %{accepted: true}} =
             Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

    assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000
    :ok
  end

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
