defmodule Dobby.DeviceAgents.HumidifierTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Humidifier,
    bindings: %{humidifier: "humidifier.contract"},
    entity: [entity_id: "humidifier.contract", device_class: "humidifier"],
    arrivals: [
      {%{result: :accepted, action: :set_power, power: :on}, %{power: :on}, %{power: :off}},
      {%{result: :accepted, action: :set_humidity, target_humidity_percent: 45},
       %{target_humidity_percent: 45}, %{target_humidity_percent: 40}},
      {%{result: :accepted, action: :set_mode, mode: "auto"}, %{mode: "auto"}, %{mode: "sleep"}}
    ],
    controls: %{
      available: true,
      type: :humidifier,
      device_class: "humidifier",
      capabilities: %{supports_modes: true, available_modes: ["auto", "sleep"]},
      target_humidity_percent: 45,
      min_humidity_percent: 30,
      max_humidity_percent: 70,
      target_humidity_step: 5,
      mode: "auto",
      power: :on
    }
  )
end
