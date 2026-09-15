defmodule Dobby.DeviceAgents.DehumidifierTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Dehumidifier,
    bindings: %{humidifier: "humidifier.contract"},
    entity: [entity_id: "humidifier.contract", device_class: "dehumidifier"],
    arrivals: [
      {%{result: :accepted, action: :set_power, power: :on}, %{power: :on}, %{power: :off}},
      {%{result: :accepted, action: :set_humidity, target_humidity_percent: 45},
       %{target_humidity_percent: 45}, %{target_humidity_percent: 40}},
      {%{result: :accepted, action: :set_mode, mode: "auto"}, %{mode: "auto"}, %{mode: "sleep"}}
    ]
  )
end
