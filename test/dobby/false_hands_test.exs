defmodule Dobby.FalseHandsTest do
  @moduledoc """
  The house's own commands, coming back from Home Assistant, are not somebody's
  hand (TK-070).

  Home Assistant does not say who moved a device. It sends a state object, and
  each device type decides whether that object is the echo of a command this
  house issued. When the type's model of the echo is narrower than what Home
  Assistant actually sends — a rounded setpoint, a brightness one point off, a
  report from halfway through a shade's travel — Dobby's own command comes back
  as "changed at the thermostat". That is a false statement about a person, in
  the household's thread.

  Every scenario here issues a real command through the rig, has the fake
  answer the way the real integration does, and then reads the thread. A test
  of `commanded?: true` would not do: the false line is written by the watcher
  from the whole report, and the flag answers only part of that question.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Conversation

  describe "a thermostat that rounds the setpoint it reports (case 6)" do
    @entity "climate.main_floor"

    setup do
      seed_house(%{@entity => thermostat_entity(target: 68)})
      settle_watcher!()
      :ok
    end

    # A Fahrenheit house reports whole degrees: `ClimateEntity` passes the
    # target through `show_temp` at the entity's precision, so 70.5 comes back
    # as 70. Nobody touched the dial.
    test "a half-degree setpoint echoed at whole degrees is ours" do
      Fake.silence_next(@entity)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.ThermostatSetTemperature, %{
                 device: "thermostat:main",
                 temperature_f: 70.5
               })

      assert_receive {:ha_call, %HACall{data: %{temperature: 70.5}}}, 2_000

      echo!(@entity, thermostat_entity(target: 70))
      deadline_passes!("thermostat:main")

      assert system_lines() == []
    end

    test "a hand that moves the dial a whole step past the command is still a hand" do
      Fake.silence_next(@entity)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.ThermostatSetTemperature, %{
                 device: "thermostat:main",
                 temperature_f: 70
               })

      echo!(@entity, thermostat_entity(target: 70))
      echo!(@entity, thermostat_entity(target: 72))

      assert [%{text: "main thermostat", meta: %{"via" => "changed at the " <> _}}] =
               system_lines()
    end
  end

  describe "a Z-Wave dimmer that echoes brightness on a 0-99 scale (case 7)" do
    @light "light.living_room"

    setup do
      seed_house(%{@light => light_entity(brightness: 26)})
      settle_watcher!()
      :ok
    end

    # HA turns 50% into brightness 128; Z-Wave JS stores round(128/255*99) =
    # 50 on the device and reports round(50/99*255) = 129 back, which is 51%.
    # Fifteen of the hundred percentages come back one point off like this,
    # and none come back two off.
    test "a brightness that comes back one point off is the command arriving" do
      Fake.silence_next(@light)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LightSetBrightness, %{
                 device: "light:living_room",
                 brightness_percent: 50
               })

      assert_receive {:ha_call, %HACall{data: %{brightness_pct: 50}}}, 2_000

      echo!(@light, light_entity(brightness: 129))
      deadline_passes!("light:living_room")

      assert system_lines() == []
    end

    test "a brightness two points off is not the command arriving" do
      Fake.silence_next(@light)

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LightSetBrightness, %{
                 device: "light:living_room",
                 brightness_percent: 50
               })

      echo!(@light, light_entity(brightness: 133))
      deadline_passes!("light:living_room")

      assert [%{meta: %{"word" => "Not known"}}] = system_lines()
    end
  end

  describe "securing what is already secure (case 4)" do
    # Home Assistant sends no state change when nothing changed, so a lock
    # command to a locked door never echoes. The nightly "lock the doors" does
    # exactly that most nights. If the accepted command stood waiting for an
    # echo, the next hand to lock that door would read as Dobby's.
    test "a hand that locks the door after Dobby locked a locked door is listed" do
      seed_house(%{"lock.front_door" => %{state: "locked", attributes: %{}}})
      settle_watcher!()

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000
      settle_watcher!()

      echo!("lock.front_door", %{state: "unlocked", attributes: %{}})
      echo!("lock.front_door", %{state: "locked", attributes: %{}})

      assert [
               %{text: "front door lock", meta: %{"value" => "Unlocked", "via" => via}},
               %{text: "front door lock", meta: %{"value" => "Locked", "via" => via}}
             ] = system_lines()

      assert via == "changed at the front door lock"
    end

    test "a hand that closes the garage after Dobby closed a closed garage is listed" do
      seed_house(%{
        "cover.garage_door" => %{state: "closed", attributes: %{current_position: 0}}
      })

      settle_watcher!()

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.AccessCoverClose, %{device: "cover:garage"})

      assert_receive {:ha_call, %HACall{entity_id: "cover.garage_door"}}, 2_000
      settle_watcher!()

      echo!("cover.garage_door", %{state: "open", attributes: %{current_position: 100}})
      echo!("cover.garage_door", %{state: "closed", attributes: %{current_position: 0}})

      assert [
               %{text: "garage door", meta: %{"via" => via}},
               %{text: "garage door", meta: %{"value" => "Closed", "via" => via}}
             ] = system_lines()

      assert via == "changed at the garage door"
    end

    # The ordinary path still works: a command that does move the lock is ours
    # when its echo lands, and a later hand is somebody's.
    test "a lock Dobby actually moved is still Dobby's, once" do
      seed_house(%{"lock.front_door" => %{state: "unlocked", attributes: %{}}})
      settle_watcher!()

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
      settle_watcher!()
      assert system_lines() == []

      echo!("lock.front_door", %{state: "unlocked", attributes: %{}})
      echo!("lock.front_door", %{state: "locked", attributes: %{}})

      assert [%{meta: %{"value" => "Unlocked"}}, %{meta: %{"value" => "Locked"}}] =
               system_lines()
    end
  end

  describe "a lock that reports locked some seconds later (case 8)" do
    # Home Assistant core does not synthesise a locking state, so a Z-Wave,
    # August or Schlage lock says nothing until the bolt has thrown and the
    # report has come back, which takes seconds, not a second.
    test "an echo a second and a half after the command is not NOT KNOWN" do
      seed_house(%{"lock.front_door" => %{state: "unlocked", attributes: %{}}})
      settle_watcher!()
      Fake.silence_next("lock.front_door")

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.LockSecure, %{device: "lock:front"})

      assert_receive {:ha_call, %HACall{entity_id: "lock.front_door"}}, 2_000
      Process.sleep(1_500)

      echo!("lock.front_door", %{state: "locked", attributes: %{}})

      assert system_lines() == []
    end
  end

  describe "a garage door with no closing state (case 2)" do
    # `CoverEntity.state` is `open` whenever the integration reports neither
    # opening, closing nor closed, so a door without an in-flight state sends
    # its position on the way down under `open`.
    setup do
      seed_house(%{
        "cover.garage_door" => %{state: "open", attributes: %{current_position: 100}}
      })

      settle_watcher!()
      Fake.silence_next("cover.garage_door")

      assert {:ok, %{accepted: true}} =
               Jido.Exec.run(Dobby.Tools.AccessCoverClose, %{device: "cover:garage"})

      assert_receive {:ha_call, %HACall{entity_id: "cover.garage_door"}}, 2_000
      :ok
    end

    test "the reports on the way down are Dobby's close" do
      echo!("cover.garage_door", %{state: "open", attributes: %{current_position: 70}})
      echo!("cover.garage_door", %{state: "open", attributes: %{current_position: 30}})
      echo!("cover.garage_door", %{state: "closed", attributes: %{current_position: 0}})
      deadline_passes!("cover:garage")

      assert system_lines() == []
    end

    test "a door that goes back up on the way down is somebody's doing" do
      echo!("cover.garage_door", %{state: "open", attributes: %{current_position: 70}})
      echo!("cover.garage_door", %{state: "open", attributes: %{current_position: 90}})

      assert [%{text: "garage door", meta: %{"via" => "changed at the garage door"}}] =
               system_lines()
    end
  end

  describe "a shade that reports on its way (case 1)" do
    @shade "cover.dining_shade"

    test "opening, reported at 40 and 70 under opening, is Dobby's open" do
      command!(shade(:closed, 0), Dobby.Tools.ShadeOpen, %{})

      echo!(@shade, shade(:opening, 40))
      echo!(@shade, shade(:opening, 70))
      echo!(@shade, shade(:open, 100))
      deadline_passes!("shade:dining")

      assert system_lines() == []
    end

    # `CoverEntity.state` is `open` until the integration says closed, so a
    # shade with no in-flight state reports open the whole way down.
    test "closing, reported at 60 and 20 under open, is Dobby's close" do
      command!(shade(:open, 100), Dobby.Tools.ShadeClose, %{})

      echo!(@shade, shade(:open, 60))
      echo!(@shade, shade(:open, 20))
      echo!(@shade, shade(:closed, 0))
      deadline_passes!("shade:dining")

      assert system_lines() == []
    end

    test "a position, reported at 80 and 60 on the way to 50, is Dobby's" do
      command!(shade(:open, 100), Dobby.Tools.ShadeSetPosition, %{position: 50})

      echo!(@shade, shade(:closing, 80))
      echo!(@shade, shade(:closing, 60))
      echo!(@shade, shade(:open, 50))
      deadline_passes!("shade:dining")

      assert system_lines() == []
    end

    test "a hand that turns the shade back on its way is somebody's doing" do
      command!(shade(:closed, 0), Dobby.Tools.ShadeOpen, %{})

      echo!(@shade, shade(:opening, 40))
      echo!(@shade, shade(:closing, 30))

      assert [%{meta: %{"via" => "changed at the dining room shade"}}] = system_lines()
    end

    # Once the command has arrived its travel is over, and the shade judges
    # reports as it did before: a hand that moves it again writes its lines.
    # The final report of a hand that returns it to the commanded end is
    # still swallowed by the standing echo; that is case 5, open in TK-064,
    # and this does not widen it.
    test "after the command arrives, a hand's travel is a hand's again" do
      command!(shade(:closed, 0), Dobby.Tools.ShadeOpen, %{})
      echo!(@shade, shade(:open, 100))
      assert system_lines() == []

      echo!(@shade, shade(:closing, 50))
      echo!(@shade, shade(:closed, 0))
      echo!(@shade, shade(:opening, 50))

      assert [%{meta: %{"value" => "Closing"}}, %{meta: %{"value" => "Closed"}}, %{meta: opening}] =
               system_lines()

      assert opening["value"] == "Opening"
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp shade(state, position) do
    %{
      state: Atom.to_string(state),
      attributes: %{current_position: position, supported_features: 4}
    }
  end

  # Seeds the shade, issues one command through its tool, and silences the
  # fake's own one-report answer so the reports the test sends are the only
  # ones the shade sees, the way a travelling shade sends them.
  defp command!(seeded, tool, args) do
    seed_house(%{@shade => seeded})
    settle_watcher!()
    Fake.silence_next(@shade)

    assert {:ok, %{accepted: true}} =
             Jido.Exec.run(tool, Map.put(args, :device, "shade:dining"))

    assert_receive {:ha_call, %HACall{entity_id: @shade}}, 2_000
    settle_watcher!()
  end

  # Home Assistant's answer, as the integration sends it. The command itself is
  # silenced in the fake, so the echo the agent sees is exactly this one.
  defp echo!(entity_id, entity) do
    :ok = Fake.inject_state_changed(entity_id, entity)
    assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
    settle_watcher!()
  end

  defp system_lines do
    Enum.filter(Conversation.list_messages(), &(&1.role == :system))
  end

  # The deadline, arriving now rather than in thirty seconds. Whatever the
  # watcher is still waiting for on this device becomes NOT KNOWN in the
  # thread; whatever an echo already answered is gone and says nothing.
  defp deadline_passes!(device) do
    Dobby.Interventions.Watcher
    |> :sys.get_state()
    |> Map.fetch!(:expectations)
    |> Enum.filter(fn {_ref, expectation} -> expectation.device == device end)
    |> Enum.each(fn {ref, _expectation} ->
      send(Dobby.Interventions.Watcher, {:expectation_expired, ref})
    end)

    settle_watcher!()
  end
end
