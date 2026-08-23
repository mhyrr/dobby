defmodule Dobby.DeviceAgents.SpeakerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Speaker,
    bindings: %{media_player: "media_player.contract"},
    entity: [entity_id: "media_player.contract", device_class: "speaker"]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not a `BadBooleanError` from `nil and`.
  test "commands before the first sync are refused, not crashed" do
    device = %Dobby.Home.Device{
      id: "speaker:boot",
      name: "boot speaker",
      agent_module: Dobby.DeviceAgents.Speaker,
      bindings: %{media_player: "media_player.boot"},
      settings: %{}
    }

    agent =
      Dobby.DeviceAgents.Speaker.new(
        id: device.id,
        state: Dobby.DeviceAgents.Speaker.initial_state(device)
      )

    assert {:ok, %{last_command: %{result: {:rejected, playback_reason}}}} =
             Dobby.DeviceAgents.Speaker.SetPlayback.run(%{playback: :play, ref: "boot"}, %{
               state: agent.state
             })

    assert playback_reason =~ "unavailable"

    assert {:ok, %{last_command: %{result: {:rejected, volume_reason}}}} =
             Dobby.DeviceAgents.Speaker.SetVolume.run(%{volume_percent: 25, ref: "boot"}, %{
               state: agent.state
             })

    assert volume_reason =~ "unavailable"
  end
end
