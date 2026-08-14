defmodule Dobby.Scenarios.MultiDeviceTest do
  @moduledoc """
  Scenario 6: "set the thermostat to 69 and check all the endpoints."

  One utterance, three devices, two device *types*, one reply. This is the
  scenario that proves Dobby is orchestrating rather than pattern-matching a
  single command — and it is the only place the parallel-versus-sequential
  tool execution question (TK-002 verify #3) can be answered.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.{DobbyAgent, Script, Utterance}

  @thermostat "thermostat:main"
  @climate "climate.main_floor"
  @tv "wifi:kitchen_tv"
  @printer "wifi:office_printer"

  setup do
    seed_house(%{
      @climate => thermostat_entity(current: 68, target: 68),
      "binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}},
      "binary_sensor.office_printer" => %{state: "off", attributes: %{}}
    })

    Trace.reset()
    :ok
  end

  test "one turn touching three devices produces exactly one HA call" do
    utterance = Utterance.new("greg", "set the thermostat to 69 and check all the endpoints")

    script =
      Script.multi_tool_turn(
        Utterance.to_message(utterance),
        [
          {"thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 69}},
          {"wifi_get_status", %{"device" => @tv}},
          {"wifi_get_status", %{"device" => @printer}}
        ],
        "Thermostat set to 69°. The kitchen TV is online; the office printer isn't responding."
      )

    assert {:ok, _reply} = DobbyAgent.say(utterance, react_opts(script))

    assert Enum.sort(Trace.tool_calls()) ==
             ["thermostat_set_temperature", "wifi_get_status", "wifi_get_status"]

    # Only the write touches Home Assistant. Both reads are answered from
    # device-agent state, which is the whole point of keeping that state warm.
    assert [%HACall{service: "set_temperature", entity_id: @climate, data: %{temperature: 69.0}}] =
             Trace.ha_calls()
  end

  test "reads of two different device types are answered from agent state" do
    assert {:ok, tv} = Jido.Exec.run(Dobby.Tools.WifiGetStatus, %{device: @tv})
    assert {:ok, printer} = Jido.Exec.run(Dobby.Tools.WifiGetStatus, %{device: @printer})

    assert tv.reachability == :online
    assert printer.reachability == :offline
    assert Trace.ha_calls() == []
  end

  test "an endpoint that has never reported is unknown, not offline" do
    # "We cannot tell" and "it is off" are different answers, and rounding one
    # into the other is how a house starts lying to you.
    boot_house!([
      %{
        id: "wifi:garage",
        name: "garage sensor",
        aliases: [],
        agent_module: Dobby.DeviceAgents.WifiEndpoint,
        network: :home_wifi,
        bindings: %{connectivity: "binary_sensor.garage"},
        settings: %{}
      }
    ])

    assert {:ok, status} = Jido.Exec.run(Dobby.Tools.WifiGetStatus, %{device: "wifi:garage"})

    assert status.reachability == :unknown
    refute status.available
  end
end
