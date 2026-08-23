defmodule Dobby.DeviceAgents.FanTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Fan,
    bindings: %{fan: "fan.contract"},
    entity: [entity_id: "fan.contract"]
  )

  # `available` is nil between agent start and the first sync — a schedule
  # firing in that window deserves a refusal, not an `ArgumentError` from
  # `not nil`.
  test "a command before the first sync is refused, not crashed" do
    device = %Dobby.Home.Device{
      id: "fan:boot",
      name: "boot fan",
      agent_module: Dobby.DeviceAgents.Fan,
      bindings: %{fan: "fan.boot"},
      settings: %{}
    }

    agent =
      Dobby.DeviceAgents.Fan.new(
        id: device.id,
        state: Dobby.DeviceAgents.Fan.initial_state(device)
      )

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Dobby.DeviceAgents.Fan.SetSpeed.run(%{speed_percent: 50, ref: "boot"}, %{
               state: agent.state
             })

    assert reason =~ "unavailable"
  end
end
