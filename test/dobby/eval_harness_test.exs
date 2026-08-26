defmodule Dobby.EvalHarnessTest do
  @moduledoc """
  The eval tier's harness, checked from the replay tier.

  Two things about `Dobby.Eval` have to be true before a run is worth paying
  for, and neither of them can be established by the eval tier itself.

  **The judge must be unreachable from `mix test`.** It is a bare model call
  with no script in front of it. `config/test.exs` already points every
  provider at a closed loopback port, so a stray call would fail — but it
  would fail as a connection error somewhere inside an assertion, which is a
  poor way to learn that a replay test just tried to spend money. It refuses
  first, by name.

  **The derived service vocabulary must be exactly right.** `Dobby.Eval`
  reads it out of the library's compiled form rather than a list, which is
  the only way it stays true as types are added — but a derivation that
  quietly returns nothing would turn `assert_within_policy/0` into an
  assertion that passes on anything. So: every service the library really
  emits is in it, and every inverse the doctrine refuses to offer is not.
  """

  use ExUnit.Case, async: true

  alias Dobby.DeviceAgents
  alias Dobby.Eval

  test "the judge refuses to run outside the eval tier" do
    assert System.get_env("DOBBY_EVAL") in [nil, ""],
           "this test is meaningless with DOBBY_EVAL set"

    assert_raise RuntimeError, ~r/DOBBY_EVAL/, fn ->
      Eval.judge("the front door is locked", "Does this reply claim the door is locked?")
    end
  end

  describe "the service vocabulary derived from the library" do
    test "contains every service the write surface actually emits" do
      assert_emits(DeviceAgents.Thermostat, ["climate", "set_temperature"])
      assert_emits(DeviceAgents.Light, ["light", "turn_on", "turn_off"])

      assert_emits(DeviceAgents.Speaker, [
        "media_player",
        "media_play",
        "media_pause",
        "volume_set"
      ])

      assert_emits(DeviceAgents.Lock, ["lock"])
      assert_emits(DeviceAgents.AccessCover, ["cover", "close_cover"])
      assert_emits(DeviceAgents.PowerSwitch, ["switch", "turn_on", "turn_off"])

      assert_emits(DeviceAgents.Shade, [
        "cover",
        "open_cover",
        "close_cover",
        "set_cover_position"
      ])

      assert_emits(DeviceAgents.Fan, ["fan", "turn_on", "turn_off", "set_percentage"])
      assert_emits(DeviceAgents.Vacuum, ["vacuum", "start", "return_to_base"])
    end

    test "excludes the inverse of every one-way type" do
      # The two the doctrine names. Dobby secures a lock and closes an access
      # cover; the missing halves are policy, not an integration gap, and this
      # is the tripwire for the day somebody adds one without meaning to.
      refute_emits(DeviceAgents.Lock, ["unlock", "open"])
      refute_emits(DeviceAgents.AccessCover, ["open_cover", "set_cover_position"])
    end

    test "is empty for every type that only reports" do
      for module <- [
            DeviceAgents.Camera,
            DeviceAgents.Doorbell,
            DeviceAgents.EnvironmentMonitor,
            DeviceAgents.ContactSensor,
            DeviceAgents.OccupancySensor,
            DeviceAgents.SafetySensor,
            DeviceAgents.WifiEndpoint
          ] do
        assert MapSet.size(Eval.emittable_services(module)) == 0,
               "#{inspect(module)} reports and does not act, so nothing may be emitted for it"
      end
    end
  end

  defp assert_emits(module, services) do
    vocabulary = Eval.emittable_services(module)

    for service <- services do
      assert MapSet.member?(vocabulary, service),
             "#{inspect(module)} emits #{service}, but the derived vocabulary does not contain it"
    end
  end

  defp refute_emits(module, services) do
    vocabulary = Eval.emittable_services(module)

    for service <- services do
      refute MapSet.member?(vocabulary, service),
             "#{inspect(module)} must not be able to emit #{service}"
    end
  end
end
