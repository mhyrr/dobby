defmodule Dobby.Agent.HouseClockTest do
  @moduledoc """
  TK-031: a Home Assistant timestamp reaches the model already converted to
  the household's own clock, on both paths it can travel — the world model
  rendered into the `<house>` block, and a status tool's own result. The
  agent's own state keeps holding whatever Home Assistant said, in HA's own
  words, because conversion belongs to rendering, not to the record.
  """

  use Dobby.RigCase, async: false

  alias Dobby.DobbyAgent
  alias Dobby.DobbyAgent.RequestTransformer
  alias Dobby.Tools.DoorbellGetStatus
  alias Dobby.Tools.WifiGetStatus

  # The rig house is `America/New_York` (`config/homes/rig.exs`); August 26th
  # is EDT, four hours behind UTC.
  @rang_at_utc "2026-08-26T19:41:07+00:00"
  @rang_at_local "2026-08-26T15:41:07-04:00"

  # This is the bug itself: the world model the prompt is built from must
  # carry the household's clock, whichever `state_phrase` clause renders a
  # doorbell — not the UTC string Home Assistant sent.
  test "the house block renders a doorbell ring in local time, never in UTC" do
    seed_house(%{
      "event.front_door" => %{
        state: @rang_at_utc,
        attributes: %{event_type: "ring", device_class: "doorbell"}
      }
    })

    world_model = await_world_model("doorbell:front", &(&1.last_event_at == @rang_at_utc))

    rendered = RequestTransformer.render(world_model)

    assert rendered =~ @rang_at_local
    refute rendered =~ "19:41"
  end

  # The second path a timestamp takes to the model: a status tool's own
  # result. `Dobby.Tools.Device.status/3` runs every reading through
  # `Dobby.Home.localize/1`, so this must answer already converted — and
  # `last_event` (not a clock) must pass through exactly as HA said it.
  test "the doorbell status tool reports the local time, not HA's UTC string" do
    seed_house(%{
      "event.front_door" => %{
        state: @rang_at_utc,
        attributes: %{event_type: "ring", device_class: "doorbell"}
      }
    })

    await_world_model("doorbell:front", &(&1.last_event_at == @rang_at_utc))

    assert {:ok, %{last_event_at: @rang_at_local, last_event: "ring"}} =
             DoorbellGetStatus.run(%{device: "doorbell:front"}, %{})
  end

  # The conversion is a rendering step, not a rewrite: the doorbell agent must
  # still hold exactly what Home Assistant sent, so a later reader of its raw
  # state (a fixture, a debugging session, a future tool) is not lied to.
  test "the doorbell agent itself still holds Home Assistant's own UTC string" do
    seed_house(%{
      "event.front_door" => %{
        state: @rang_at_utc,
        attributes: %{event_type: "ring", device_class: "doorbell"}
      }
    })

    await_world_model("doorbell:front", &(&1.last_event_at == @rang_at_utc))

    assert agent_state("doorbell:front").last_event_at == @rang_at_utc
  end

  # WifiEndpoint stamps `last_changed_at` with `DateTime.utc_now/0`, a
  # `%DateTime{}` rather than a string — the other shape `Dobby.Home.local_iso8601/1`
  # has to handle. Both the tool result and the house block must carry the
  # same local reading, and neither may leak Elixir's own `~U[...]` syntax.
  test "wifi's last_changed_at reaches the tool result and the house block already local" do
    seed_house(%{"binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}}})

    Fake.inject_state_changed("binary_sensor.kitchen_tv", %{state: "off", attributes: %{}})

    changed_at =
      eventually(fn ->
        case agent_state("wifi:kitchen_tv").last_changed_at do
          %DateTime{} = at -> at
          _not_stamped_yet -> false
        end
      end)

    expected = changed_at |> Dobby.Home.local() |> DateTime.to_iso8601()

    assert {:ok, %{last_changed_at: ^expected}} =
             WifiGetStatus.run(%{device: "wifi:kitchen_tv"}, %{})

    world_model =
      await_world_model("wifi:kitchen_tv", &match?(%DateTime{}, &1.last_changed_at))

    rendered = RequestTransformer.render(world_model)

    assert rendered =~ expected
    refute rendered =~ "~U["
  end

  # `local_iso8601/1` is a timestamp converter, not a blanket string mangler —
  # `nil`, booleans, an appliance's own vocabulary word, and plain numbers are
  # not clocks and must come back exactly as given.
  test "local_iso8601/1 leaves values that are not timestamps alone" do
    assert Dobby.Home.local_iso8601(nil) == nil
    assert Dobby.Home.local_iso8601(true) == true
    assert Dobby.Home.local_iso8601(false) == false
    assert Dobby.Home.local_iso8601("ring") == "ring"
    assert Dobby.Home.local_iso8601(42) == 42
    assert Dobby.Home.local_iso8601(:on) == :on
  end

  # A string already in the household's own zone must survive a second pass
  # unchanged — the renderer calls `localize/1` on every snapshot, including
  # one already converted upstream (an appliance's own `:timestamp` reading).
  test "local_iso8601/1 is idempotent on a string already in local time" do
    already_local = "2026-08-26T15:41:07-04:00"
    assert Dobby.Home.local_iso8601(already_local) == already_local
  end

  # The one sentence doctrine requires: the model is told which zone "local"
  # means, by name, so it has something to defer to instead of a UTC digit it
  # could do arithmetic on.
  test "the house block names the household's timezone" do
    rendered = RequestTransformer.render(%{})
    assert rendered =~ "America/New_York"
  end

  defp await_world_model(device_id, predicate) do
    eventually(fn ->
      world = Map.get(agent_state(DobbyAgent.id()), :world_model) || %{}

      case Map.get(world, device_id) do
        nil -> false
        snapshot -> (predicate.(snapshot) && world) || false
      end
    end)
  end
end
