defmodule Dobby.DeviceAgents.ShadeTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Shade,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "shade"]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not an `ArgumentError` from `not nil`.
  test "a command before the first sync is refused, not crashed" do
    device = %Dobby.Home.Device{
      id: "shade:boot",
      name: "boot shade",
      agent_module: Dobby.DeviceAgents.Shade,
      bindings: %{cover: "cover.boot"},
      settings: %{}
    }

    agent =
      Dobby.DeviceAgents.Shade.new(
        id: device.id,
        state: Dobby.DeviceAgents.Shade.initial_state(device)
      )

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Dobby.DeviceAgents.Shade.SetPosition.run(%{position: 40, ref: "boot"}, %{
               state: agent.state
             })

    assert reason =~ "unavailable"
  end
end
